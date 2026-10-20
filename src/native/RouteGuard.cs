using System;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;
using System.Net.NetworkInformation;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class RouteGuard {
    [StructLayout(LayoutKind.Sequential)] public struct Row {
        public UInt64 Luid;
        public UInt32 InterfaceIndex;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=32)] public byte[] Destination;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=28)] public byte[] NextHop;
        public byte SitePrefixLength;
        public UInt32 ValidLifetime, PreferredLifetime, Metric, Protocol;
        public byte Loopback, Autoconfigure, Publish, Immortal;
        public UInt32 Age, Origin;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void RouteCallback(IntPtr context, IntPtr row, int type);
    [DllImport("iphlpapi.dll")] static extern uint GetIpForwardTable2(ushort family, out IntPtr table);
    [DllImport("iphlpapi.dll")] static extern void FreeMibTable(IntPtr table);
    [DllImport("iphlpapi.dll")] static extern uint DeleteIpForwardEntry2(IntPtr row);
    [DllImport("iphlpapi.dll")] static extern uint NotifyRouteChange2(ushort family, RouteCallback callback, IntPtr context, [MarshalAs(UnmanagedType.U1)] bool initial, out IntPtr handle);
    [DllImport("iphlpapi.dll")] static extern uint CancelMibChangeNotify2(IntPtr handle);
    const uint ErrorNotFound = 1168;
    const long MaxLogBytes = 1024 * 1024;
    static AutoResetEvent changed = new AutoResetEvent(false);
    static string folder;
    static JavaScriptSerializer json = new JavaScriptSerializer();
    static RouteCallback callback = delegate(IntPtr c,IntPtr r,int t) { changed.Set(); };
    static Dictionary<string,DateTime> lastLogged = new Dictionary<string,DateTime>();
    static Dictionary<string,int> suppressed = new Dictionary<string,int>();

    static int FindIndex(string guid) {
        foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces()) {
            if (!String.Equals(nic.Id.Trim('{','}'),guid.Trim('{','}'),StringComparison.OrdinalIgnoreCase)) continue;
            try {
                IPv4InterfaceProperties p=nic.GetIPProperties().GetIPv4Properties();
                if (p!=null) return p.Index;
            } catch (NetworkInformationException) {}
        }
        return -1;
    }
    static void Log(string message) {
        try {
            string path=Path.Combine(folder,"route-guard.log");
            FileInfo info=new FileInfo(path);
            if (info.Exists && info.Length>MaxLogBytes) {
                string old=Path.Combine(folder,"route-guard.old.log");
                if (File.Exists(old)) File.Delete(old);
                File.Move(path,old);
            }
            File.AppendAllText(path,DateTimeOffset.Now.ToString("o")+" "+message+Environment.NewLine);
        } catch {}
    }
    // Repeating problems are written at most once per window, with a count of what was skipped.
    static void LogLimited(string key,string message,int seconds) {
        DateTime now=DateTime.UtcNow, last;
        if (lastLogged.TryGetValue(key,out last) && (now-last).TotalSeconds<seconds) {
            int count; suppressed.TryGetValue(key,out count); suppressed[key]=count+1;
            return;
        }
        int skipped; suppressed.TryGetValue(key,out skipped);
        Log(message+(skipped>0?" (+"+skipped+" similar since last entry)":""));
        lastLogged[key]=now; suppressed[key]=0;
    }
    static List<object> Scan(int index,bool remove) {
        IntPtr table;
        uint code=GetIpForwardTable2(2,out table);
        if(code!=0) throw new Exception("GetIpForwardTable2 error "+code);
        List<object> list=new List<object>();
        try {
            int count=Marshal.ReadInt32(table);
            int size=Marshal.SizeOf(typeof(Row));
            if(size!=104 || Marshal.OffsetOf(typeof(Row),"Destination").ToInt32()!=12 || Marshal.OffsetOf(typeof(Row),"NextHop").ToInt32()!=44) throw new Exception("Unexpected route struct layout");
            for(int n=0;n<count;n++) {
                IntPtr ptr=IntPtr.Add(table,8+n*size);
                Row r=(Row)Marshal.PtrToStructure(ptr,typeof(Row));
                if(r.InterfaceIndex!=index || r.Destination[28]!=0) continue;
                string hop=r.NextHop[4]+"."+r.NextHop[5]+"."+r.NextHop[6]+"."+r.NextHop[7];
                uint result=0;
                if(remove) result=DeleteIpForwardEntry2(ptr);
                list.Add(new {InterfaceIndex=r.InterfaceIndex, NextHop=hop, Metric=r.Metric, DeleteResult=result});
                if(!remove) continue;
                if(result==0 || result==ErrorNotFound) LogLimited("remove-ok","DEFAULT_ROUTE_REMOVE index="+index+" nextHop="+hop+" result="+result,10);
                else LogLimited("remove-fail","DEFAULT_ROUTE_REMOVE_FAILED index="+index+" nextHop="+hop+" result="+result,60);
            }
        } finally {FreeMibTable(table);}
        return list;
    }
    public static int Main(string[] args) {
        if(args.Length<2) return 2;
        string mode=args[0],guid=args[1];
        folder=args.Length>2?args[2]:AppDomain.CurrentDomain.BaseDirectory;
        try {
            Directory.CreateDirectory(folder);
            if(mode=="--scan") {
                File.WriteAllText(Path.Combine(folder,"native-scan.json"),json.Serialize(Scan(FindIndex(guid),false)));
                return 0;
            }
        } catch(Exception e) {
            Log("ERROR "+e.ToString());
            return 1;
        }
        if(mode!="--watch") return 2;
        // Single instance via a lock file in the admin-only data folder; a global mutex name could be taken first by any user.
        // Only a sharing conflict means another guard holds it; retry briefly, since backup or antivirus software can open it too.
        FileStream instance=null;
        for(int attempt=0; instance==null; attempt++) {
            try {instance=new FileStream(Path.Combine(folder,"guard.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);}
            catch(IOException e) {
                int code=Marshal.GetHRForException(e)&0xFFFF;
                if(code!=32 && code!=33) {Log("ERROR cannot open guard.lock: "+e.Message); return 1;}
                if(attempt>=5) {Log("ALREADY_RUNNING pid="+System.Diagnostics.Process.GetCurrentProcess().Id+" exiting"); return 0;}
                Thread.Sleep(1000);
            }
            catch(Exception e) {Log("ERROR cannot open guard.lock: "+e.Message); return 1;}
        }
        using(instance) {
            IntPtr notification=IntPtr.Zero;
            uint error=NotifyRouteChange2(2,callback,IntPtr.Zero,true,out notification);
            if(error!=0) {notification=IntPtr.Zero; Log("NOTIFY_UNAVAILABLE error="+error+"; checking every 500 ms only");}
            Log("START guid="+guid+" pid="+System.Diagnostics.Process.GetCurrentProcess().Id);
            string heartbeat=Path.Combine(folder,"guard-heartbeat.txt");
            int lastIndex=int.MinValue;
            try {
                // Nothing in the loop may end the process: a transient error is logged and retried on the next pass.
                // The heartbeat is written only after a pass that worked, so a guard that keeps failing shows as not running.
                while(true) {
                    bool passed=false;
                    try {
                        int index=FindIndex(guid);
                        if(index!=lastIndex) {Log(index>0?"ADAPTER index="+index:"ADAPTER_NOT_FOUND guid="+guid); lastIndex=index;}
                        if(index>0) Scan(index,true);
                        passed=true;
                    } catch(Exception e) {LogLimited("loop","ERROR "+e.GetType().Name+": "+e.Message,60);}
                    if(passed) {
                        try {File.WriteAllText(heartbeat,DateTimeOffset.Now.ToString("o"));}
                        catch(Exception e) {LogLimited("heartbeat","HEARTBEAT_FAIL "+e.Message,60);}
                    }
                    changed.WaitOne(500);
                }
            } finally {if(notification!=IntPtr.Zero) CancelMibChangeNotify2(notification);}
        }
    }
}
