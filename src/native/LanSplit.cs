using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Diagnostics;
using System.Collections;
using System.Collections.Generic;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Web.Script.Serialization;

// Every color has one job: structure (page, ink, muted, line), the accent only for the primary action and focus,
// and one set per status level.
static class Palette {
    public static readonly Color Page = Rgb(0xF6F7F9), Surface = Color.White, Ink = Rgb(0x1D2A39), Muted = Rgb(0x5B6675), Faint = Rgb(0x9AA3AF), Line = Rgb(0xDDE2E8);
    public static readonly Color Accent = Rgb(0x2554D2), AccentHover = Rgb(0x1D46B8), AccentPressed = Rgb(0x173A9C);
    public static readonly Color Danger = Rgb(0xB3261E), DangerHover = Rgb(0x952019), DangerTint = Rgb(0xFBEAE8);
    public static readonly Color DisabledFill = Rgb(0xE8EBEF), DisabledText = Rgb(0x8B95A3);
    public static Color Rgb(int v) { return Color.FromArgb((v >> 16) & 255, (v >> 8) & 255, v & 255); }
    public static Color Band(string level) {
        switch (level) { case "ok": return Rgb(0xE6F3EB); case "warn": return Rgb(0xFCF1DA); case "error": return Rgb(0xFBE8E6); default: return Rgb(0xECEFF3); }
    }
    public static Color Strong(string level) {
        switch (level) { case "ok": return Rgb(0x1F7A4D); case "warn": return Rgb(0xA35F00); case "error": return Rgb(0xC42B1C); case "off": return Faint; default: return Muted; }
    }
    public static Color Text(string level) {
        switch (level) { case "ok": return Rgb(0x135C37); case "warn": return Rgb(0x6B4100); case "error": return Rgb(0x8C1D14); default: return Ink; }
    }
    public static Color Blend(Color a, Color b, float t) {
        return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
}

// Scale for the current DPI (and, in preview mode, a simulated display scale).
class Ui {
    public readonly float Scale, FontFactor;
    public Ui(float scale, float fontFactor) { Scale = scale; FontFactor = fontFactor; }
    public int Px(float v) { return (int)Math.Round(v * Scale); }
    public Font Font(float pt, bool bold) { return new Font("Microsoft YaHei UI", pt * FontFactor, bold ? FontStyle.Bold : FontStyle.Regular); }
    public static GraphicsPath Rounded(RectangleF r, float radius) {
        GraphicsPath path = new GraphicsPath();
        float d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

// Round status mark drawn as vectors: solid for ok/warn/error, outline for info/off, a turning arc while busy.
class StatusIcon : Control {
    string kind = "off";
    bool solidAllowed = true;
    float angle;
    public StatusIcon() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent; TabStop = false;
    }
    public string Kind { get { return kind; } }
    bool dim;
    public bool Dim { get { return dim; } set { if (dim != value) { dim = value; Invalidate(); } } }
    public void Set(string newKind, bool solid) {
        kind = newKind; solidAllowed = solid;
        AccessibleName = newKind == "ok" ? "正常" : newKind == "warn" ? "需要处理" : newKind == "error" ? "有问题" : newKind == "busy" ? "处理中" : newKind == "info" ? "说明" : newKind == "pending" ? "读取中" : "未启用";
        Invalidate();
    }
    public void Spin() { angle = (angle + 8) % 360; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float s = Math.Min(Width, Height) - 1.5f;
        RectangleF r = new RectangleF(0.75f, 0.75f, s, s);
        if (kind == "busy") {
            using (Pen track = new Pen(Palette.Line, s * 0.11f)) g.DrawEllipse(track, r);
            using (Pen arc = new Pen(Palette.Accent, s * 0.11f)) { arc.StartCap = LineCap.Round; arc.EndCap = LineCap.Round; g.DrawArc(arc, r, angle, 110); }
            return;
        }
        if (kind == "pending") { using (Pen p = new Pen(Palette.Faint, Math.Max(1f, s * 0.08f))) g.DrawEllipse(p, r); return; }
        Color c = dim ? Palette.Faint : Palette.Strong(kind);
        bool solid = solidAllowed && (kind == "ok" || kind == "warn" || kind == "error");
        Color glyph = solid ? Color.White : c;
        if (solid) { using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, r); }
        else { using (Pen p = new Pen(c, Math.Max(1f, s * 0.08f))) g.DrawEllipse(p, r); }
        using (Pen p = new Pen(glyph, Math.Max(1.4f, s * 0.11f)))
        using (SolidBrush dot = new SolidBrush(glyph)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            float dr = Math.Max(1.1f, s * 0.065f);
            switch (kind) {
                case "ok": g.DrawLines(p, new PointF[] { At(r, .29f, .53f), At(r, .44f, .67f), At(r, .72f, .37f) }); break;
                case "warn": g.DrawLine(p, At(r, .5f, .26f), At(r, .5f, .55f)); g.FillEllipse(dot, r.X + r.Width * .5f - dr, r.Y + r.Height * .72f - dr, dr * 2, dr * 2); break;
                case "error": g.DrawLine(p, At(r, .35f, .35f), At(r, .65f, .65f)); g.DrawLine(p, At(r, .65f, .35f), At(r, .35f, .65f)); break;
                case "info": g.FillEllipse(dot, r.X + r.Width * .5f - dr, r.Y + r.Height * .29f - dr, dr * 2, dr * 2); g.DrawLine(p, At(r, .5f, .45f), At(r, .5f, .73f)); break;
                default: g.DrawLine(p, At(r, .33f, .5f), At(r, .67f, .5f)); break;
            }
        }
    }
    static PointF At(RectangleF r, float x, float y) { return new PointF(r.X + r.Width * x, r.Y + r.Height * y); }
}

enum ButtonKind { Primary, Secondary, Danger, DangerFilled, Link }

// One button grammar for the whole tool: 4px corners, 1px border, visible hover/pressed/focus/disabled.
class ActionButton : Button {
    public ButtonKind Kind;
    readonly Ui ui;
    bool hover, pressed;
    public ActionButton(ButtonKind kind, Ui ui, Font font, string text) {
        Kind = kind; this.ui = ui; Font = font; Text = text;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat; Cursor = Cursors.Hand; UseVisualStyleBackColor = false;
        Fit();
    }
    public void Fit() {
        Size t = TextRenderer.MeasureText(Text, Font, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        if (Kind == ButtonKind.Link) { Size = new Size(t.Width + ui.Px(8), t.Height + ui.Px(8)); return; }
        Size = new Size(Math.Max(ui.Px(96), t.Width + ui.Px(36)), Math.Max(ui.Px(34), t.Height + ui.Px(14)));
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { pressed = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        Color back = Parent != null ? Parent.BackColor : Palette.Page;
        g.Clear(back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color fill = back, border = Color.Empty, text = Palette.Ink;
        bool on = Enabled;
        switch (Kind) {
            case ButtonKind.Primary:
                fill = !on ? Palette.DisabledFill : pressed ? Palette.AccentPressed : hover ? Palette.AccentHover : Palette.Accent;
                text = on ? Color.White : Palette.DisabledText; break;
            case ButtonKind.DangerFilled:
                fill = !on ? Palette.DisabledFill : pressed || hover ? Palette.DangerHover : Palette.Danger;
                text = on ? Color.White : Palette.DisabledText; break;
            case ButtonKind.Secondary:
                fill = !on ? Palette.DisabledFill : pressed ? Palette.Rgb(0xE3E8EF) : hover ? Palette.Rgb(0xEEF2F7) : Palette.Surface;
                border = on ? Palette.Rgb(0xC9D0DA) : Color.Empty; text = on ? Palette.Ink : Palette.DisabledText; break;
            case ButtonKind.Danger:
                fill = !on ? Palette.DisabledFill : pressed ? Palette.Rgb(0xF6D6D2) : hover ? Palette.DangerTint : Palette.Surface;
                border = on ? Palette.Danger : Color.Empty; text = on ? Palette.Danger : Palette.DisabledText; break;
            case ButtonKind.Link:
                text = !on ? Palette.DisabledText : pressed ? Palette.AccentPressed : Palette.Accent; break;
        }
        RectangleF box = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        if (Kind != ButtonKind.Link) {
            using (GraphicsPath path = Ui.Rounded(box, ui.Px(4))) {
                using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, path);
                if (border != Color.Empty) using (Pen p = new Pen(border, 1f)) g.DrawPath(p, path);
            }
        }
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, text, back == fill || Kind == ButtonKind.Link ? back : fill,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        if (Kind == ButtonKind.Link && hover && on) {
            Size t = TextRenderer.MeasureText(Text, Font, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
            int y = (Height + t.Height) / 2 - 1, x = (Width - t.Width) / 2;
            using (Pen p = new Pen(text, 1f)) g.DrawLine(p, x, y, x + t.Width, y);
        }
        if (Focused && ShowFocusCues) {
            using (GraphicsPath ring = Ui.Rounded(new RectangleF(1.5f, 1.5f, Width - 3.5f, Height - 3.5f), ui.Px(3)))
            using (Pen p = new Pen(Kind == ButtonKind.Primary || Kind == ButtonKind.DangerFilled ? Color.White : Palette.Accent, 2f)) g.DrawPath(p, ring);
        }
    }
}

// Thin indeterminate bar along the bottom edge of the status band.
class ProgressStrip : Control {
    float position = 0.35f;
    public ProgressStrip() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); TabStop = false; }
    public void Step() { position += 0.014f; if (position > 1) position = 0; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(Parent != null ? Parent.BackColor : Palette.Page);
        float segment = Width * 0.3f, x = position * (Width + segment) - segment;
        using (SolidBrush b = new SolidBrush(Palette.Accent)) e.Graphics.FillRectangle(b, x, 0, segment, Height);
    }
}

class BufferedPanel : Panel {
    public BufferedPanel() { DoubleBuffered = true; SetStyle(ControlStyles.ResizeRedraw, true); }
}

// Confirmation for changes that cannot be undone with one click: the consequence first, the button names the action.
class ConfirmDialog : Form {
    public static bool Ask(IWin32Window owner, Ui ui, string title, string consequence, string[] details, string action, bool danger) {
        using (ConfirmDialog d = new ConfirmDialog(ui, title, consequence, details, action, danger)) return d.ShowDialog(owner) == DialogResult.OK;
    }
    public ConfirmDialog(Ui ui, string title, string consequence, string[] details, string action, bool danger) {
        Text = title; FormBorderStyle = FormBorderStyle.FixedDialog; StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false; MaximizeBox = false; ShowInTaskbar = false; BackColor = Palette.Surface; AutoScaleMode = AutoScaleMode.None;
        Font = ui.Font(10.5f, false); KeyPreview = true;
        int width = ui.Px(460), pad = ui.Px(24), y = ui.Px(22);
        Label head = new Label { AutoSize = true, MaximumSize = new Size(width - pad * 2, 0), Text = consequence, Font = ui.Font(11.5f, true), ForeColor = Palette.Ink, Location = new Point(pad, y) };
        Controls.Add(head); y = head.Bottom + ui.Px(12);
        // Bullets are drawn dots centred on the first text line, not a punctuation character.
        List<PointF> dots = new List<PointF>();
        int textX = pad + ui.Px(4) + ui.Px(8);
        foreach (string line in details) {
            Label item = new Label { AutoSize = true, MaximumSize = new Size(width - textX - pad, 0), Text = line, ForeColor = Palette.Ink, Location = new Point(textX, y) };
            Controls.Add(item);
            dots.Add(new PointF(pad + ui.Px(2), y + TextRenderer.MeasureText("国", item.Font).Height / 2f));
            y = item.Bottom + ui.Px(6);
        }
        float radius = ui.Px(4) / 2f;
        Paint += delegate(object s, PaintEventArgs e) {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush b = new SolidBrush(Palette.Muted)) foreach (PointF p in dots) e.Graphics.FillEllipse(b, p.X - radius, p.Y - radius, radius * 2, radius * 2);
        };
        y += ui.Px(16);
        ActionButton cancel = new ActionButton(ButtonKind.Secondary, ui, ui.Font(10.5f, false), "取消") { DialogResult = DialogResult.Cancel };
        ActionButton go = new ActionButton(danger ? ButtonKind.DangerFilled : ButtonKind.Primary, ui, ui.Font(10.5f, false), action) { DialogResult = DialogResult.OK };
        cancel.Location = new Point(width - pad - cancel.Width, y);
        go.Location = new Point(cancel.Left - ui.Px(10) - go.Width, y);
        Controls.Add(go); Controls.Add(cancel);
        CancelButton = cancel; ActiveControl = cancel;
        ClientSize = new Size(width, cancel.Bottom + ui.Px(20));
    }
}

// A program file is missing or differs from the build; the message names the file.
class IntegrityException : Exception { public IntegrityException(string message) : base(message) {} }

// Copies the backend into the admin-only data folder after checking it against the hashes built into this exe.
static class Engine {
    const long WriteMask = 0x500D0156;
    static readonly string[] TrustedOwners = { "S-1-5-18", "S-1-5-32-544", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" };
    static bool TrustedOwner(string sid) { return TrustedOwners.Contains(sid); }
    static bool TrustedAce(string sid) { return TrustedOwner(sid) || sid == "S-1-3-0"; }
    public static string TrustProblem(FileSystemSecurity security) {
        SecurityIdentifier owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner == null || !TrustedOwner(owner.Value)) return "所有者为 " + (owner == null ? "未知" : owner.Value);
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType != AccessControlType.Allow || TrustedAce(rule.IdentityReference.Value)) continue;
            if ((unchecked((long)(int)rule.FileSystemRights) & WriteMask) != 0) return rule.IdentityReference.Value + " 可以写入";
        }
        return null;
    }
    static DirectorySecurity Protected() {
        DirectorySecurity security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (WellKnownSidType type in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(type, null), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        return security;
    }
    public static void EnsureRoot(string root) {
        if (!Directory.Exists(root)) { Directory.CreateDirectory(root, Protected()); return; }
        DirectorySecurity current = Directory.GetAccessControl(root);
        string problem = TrustProblem(current);
        if (problem == null) return;
        SecurityIdentifier owner = current.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner == null || !TrustedOwner(owner.Value))
            throw new InvalidOperationException("数据目录 " + root + " 的权限异常（" + problem + "），可能被其他程序预先创建。为安全起见已停止，请管理员检查后删除该目录。");
        Directory.SetAccessControl(root, Protected());
        // Anything put inside while the folder was open keeps its own owner and explicit rights.
        foreach (FileSystemInfo item in new DirectoryInfo(root).EnumerateFileSystemInfos("*", SearchOption.AllDirectories)) {
            string inner = TrustProblem(item is DirectoryInfo ? (FileSystemSecurity)Directory.GetAccessControl(item.FullName) : File.GetAccessControl(item.FullName));
            if (inner != null) throw new InvalidOperationException("数据目录里的 " + item.FullName + " 权限异常（" + inner + "）。为安全起见已停止，请管理员检查。");
        }
    }
    // Files this tool writes belong to Administrators, also where new objects default to the creating user.
    static void AdminOwner(string path) {
        try {
            FileSecurity owner = new FileSecurity();
            owner.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            File.SetAccessControl(path, owner);
        } catch {}
    }
    static string Sha256(byte[] bytes) {
        using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
    }
    public static string Prepare(string root, string package) {
        EnsureRoot(root);
        string engine = Path.Combine(root, "app");
        if (Directory.Exists(engine) && TrustProblem(Directory.GetAccessControl(engine)) != null) Directory.Delete(engine, true);
        Directory.CreateDirectory(engine);
        foreach (string[] file in BuildInfo.EngineFiles) {
            string source = Path.Combine(package, file[0]);
            if (!File.Exists(source)) throw new IntegrityException("程序文件夹里缺少 " + file[0] + "。请从完整解压的程序文件夹运行。");
            byte[] bytes = File.ReadAllBytes(source);
            if (!string.Equals(Sha256(bytes), file[1], StringComparison.OrdinalIgnoreCase))
                throw new IntegrityException(file[0] + " 和构建时不一致，可能被改过。请重新解压完整的程序，或重新运行 build.ps1。");
            // An identical, trusted copy is left alone, so a backend that is running from it is not disturbed.
            string target = Path.Combine(engine, file[0]);
            if (File.Exists(target) && TrustProblem(File.GetAccessControl(target)) == null && string.Equals(Sha256(File.ReadAllBytes(target)), file[1], StringComparison.OrdinalIgnoreCase)) continue;
            // Otherwise write the bytes that were checked to a new file and swap it in, so nothing can change them between check and use.
            string temp = target + ".tmp";
            if (File.Exists(temp)) File.Delete(temp);
            File.WriteAllBytes(temp, bytes);
            AdminOwner(temp);
            if (File.Exists(target)) File.Replace(temp, target, null); else File.Move(temp, target);
        }
        return engine;
    }
}

class CheckRow {
    public StatusIcon Icon = new StatusIcon();
    public Label Name, Detail, Role;
    public ActionButton Link;
}

public class SplitWindow : Form {
    const int ContentWidth = 600;
    readonly Ui ui;
    readonly string package, root, powershell;
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly bool IsPreview;
    Font fTitle, fBody, fSmall, fSection;
    BufferedPanel band, notice, logPanel;
    StatusIcon bandIcon, noticeIcon;
    Label title, reason, noticeTitle, noticeText, noticeNote, lastCheckLabel, checksHeader, nicHeader, lastLogLabel, disclaimer;
    ActionButton primary, recheck, renew, restore, noticeLog, noticeRetry, logToggle, openFolder, help;
    ProgressStrip progress;
    Panel divider;
    TextBox logBox;
    readonly ToolTip tips = new ToolTip();
    readonly List<CheckRow> checkRows = new List<CheckRow>();
    readonly List<CheckRow> nicRows = new List<CheckRow>();
    Timer poll, anim;
    Process child;
    string resultPath, busyMode, busyLabel, view = "loading", unknownReason, opErrorTitle, opError, primaryAction, failedMode, failedLabel;
    Dictionary<string, object> status;
    DateTime jobStarted, lastCheck;
    bool logExpanded, killedForTimeout, autoRefreshAfterFailure;
    Color bandFrom, bandTo; float bandT = 1;
    // Self-test: three real read-only status checks, then a screenshot.
    readonly string selfTestPath; int selfTestRuns; bool selfTestOk = true;
    readonly HashSet<Control> hidden = new HashSet<Control>();

    public SplitWindow(string[] args) : this(args, 1f, false) {}
    SplitWindow(string[] args, float previewScale, bool preview) {
        IsPreview = preview;
        package = AppDomain.CurrentDomain.BaseDirectory;
        root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WifiLanSplit");
        powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        if (args.Length > 1 && args[0] == "--selftest") selfTestPath = args[1];
        float dpi;
        using (Graphics g = CreateGraphics()) dpi = g.DpiX;
        ui = new Ui(dpi / 96f * previewScale, previewScale);
        fTitle = ui.Font(16f, true); fBody = ui.Font(10.5f, false); fSmall = ui.Font(10f, false); fSection = ui.Font(10f, true);
        Text = "双网分流"; AutoScaleMode = AutoScaleMode.None; Font = fBody; BackColor = Palette.Page; ForeColor = Palette.Ink;
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen; KeyPreview = true;
        Icon = MakeIcon();
        Build();
        bandFrom = bandTo = Palette.Band("neutral");
        ApplyView();
        poll = new Timer { Interval = 150 }; poll.Tick += delegate { Poll(); };
        anim = new Timer { Interval = 16 }; anim.Tick += delegate { Animate(); };
        if (!preview) {
            poll.Start();
            Shown += delegate { CleanStaleResults(); StartJob("Status"); };
        }
        FormClosing += OnClosing;
        KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.F5 && busyMode == null) StartJob("Status"); };
    }
    // Control.Visible reads false until the window is shown, so layout tracks the intended visibility itself.
    void Reveal(Control c, bool on) { c.Visible = on; if (on) hidden.Remove(c); else hidden.Add(c); }
    bool IsOn(Control c) { return !hidden.Contains(c); }

    Label NewLabel(Control parent, Font font, Color color) {
        Label l = new Label { AutoSize = true, Font = font, ForeColor = color, BackColor = Color.Transparent, UseMnemonic = false };
        parent.Controls.Add(l); return l;
    }
    ActionButton NewButton(Control parent, ButtonKind kind, string text, Font font, EventHandler click) {
        ActionButton b = new ActionButton(kind, ui, font, text); b.Click += click; parent.Controls.Add(b); return b;
    }
    static void RoundedBorder(Control c, PaintEventArgs e, Ui ui) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath path = Ui.Rounded(new RectangleF(0.5f, 0.5f, c.Width - 1.5f, c.Height - 1.5f), ui.Px(4)))
        using (Pen p = new Pen(Palette.Line)) e.Graphics.DrawPath(p, path);
    }
    void Build() {
        band = new BufferedPanel { BackColor = Palette.Band("neutral") };
        Controls.Add(band);
        bandIcon = new StatusIcon(); band.Controls.Add(bandIcon);
        title = NewLabel(band, fTitle, Palette.Ink);
        reason = NewLabel(band, fBody, Palette.Ink);
        primary = NewButton(band, ButtonKind.Primary, "重新检查", fBody, delegate { RunPrimary(); });
        progress = new ProgressStrip(); band.Controls.Add(progress); Reveal(progress, false);

        // A failed action is reported once, on its own strip, so the status colour above only describes the current state.
        notice = new BufferedPanel { BackColor = Palette.Surface };
        notice.Paint += delegate(object s, PaintEventArgs e) { RoundedBorder(notice, e, ui); };
        Controls.Add(notice); Reveal(notice, false);
        noticeIcon = new StatusIcon(); noticeIcon.Set("error", true); notice.Controls.Add(noticeIcon);
        noticeTitle = NewLabel(notice, fBody, Palette.Text("error"));
        noticeText = NewLabel(notice, fBody, Palette.Ink);
        noticeNote = NewLabel(notice, fSmall, Palette.Muted); noticeNote.Text = "上方是操作之后重新检查的结果。";
        noticeRetry = NewButton(notice, ButtonKind.Link, "再试一次", fSmall, delegate { busyLabel = failedLabel; StartJob(failedMode); });
        noticeLog = NewButton(notice, ButtonKind.Link, "查看日志", fSmall, delegate { logExpanded = true; ApplyView(); });

        checksHeader = NewLabel(this, fSection, Palette.Muted); checksHeader.Text = "检查项";
        lastCheckLabel = NewLabel(this, fSmall, Palette.Muted);
        recheck = NewButton(this, ButtonKind.Link, "重新检查", fSmall, delegate { StartJob("Status"); });
        nicHeader = NewLabel(this, fSection, Palette.Muted); nicHeader.Text = "网卡";
        renew = NewButton(this, ButtonKind.Secondary, "有线续租并验证", fBody, delegate { StartJob("Renew"); });
        tips.SetToolTip(renew, "只对网线重新获取 DHCP 地址，然后确认网线默认路由仍为 0、看守和 Wi-Fi 正常。");
        restore = NewButton(this, ButtonKind.Danger, "还原设置…", fBody, delegate { AskRestore(); });
        divider = new Panel { BackColor = Palette.Line, Height = 1 }; Controls.Add(divider);
        lastLogLabel = NewLabel(this, fSmall, Palette.Muted); lastLogLabel.AutoSize = false; lastLogLabel.AutoEllipsis = true;
        logToggle = NewButton(this, ButtonKind.Link, "查看日志", fSmall, delegate { logExpanded = !logExpanded; ApplyView(); });
        openFolder = NewButton(this, ButtonKind.Link, "打开数据文件夹", fSmall, delegate { OpenFolder(); });
        help = NewButton(this, ButtonKind.Link, "使用说明", fSmall, delegate { OpenHelp(); });
        // The log sits on a white rounded panel; its scroll bar appears only when the text is longer than the box.
        logPanel = new BufferedPanel { BackColor = Palette.Surface, Padding = new Padding(ui.Px(10), ui.Px(8), ui.Px(4), ui.Px(8)) };
        logPanel.Paint += delegate(object s, PaintEventArgs e) { RoundedBorder(logPanel, e, ui); };
        logBox = new TextBox { Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = Palette.Surface, ForeColor = Palette.Ink, Font = fSmall, ScrollBars = ScrollBars.None, Dock = DockStyle.Fill, TabStop = false, WordWrap = true };
        logPanel.Controls.Add(logBox);
        Controls.Add(logPanel); Reveal(logPanel, false);
        disclaimer = NewLabel(this, fSmall, Palette.Muted);
        disclaimer.Text = "只核对配置，不抓包测试实际流量。经内网代理或隧道的访问不受本工具限制。";
    }

    // ---------- view ----------
    static bool B(Dictionary<string, object> d, string key) { return d != null && d.ContainsKey(key) && d[key] != null && Convert.ToBoolean(d[key]); }
    static string S(Dictionary<string, object> d, string key) { return d != null && d.ContainsKey(key) && d[key] != null ? Convert.ToString(d[key]) : ""; }
    static Dictionary<string, object> D(Dictionary<string, object> d, string key) { return d != null && d.ContainsKey(key) ? d[key] as Dictionary<string, object> : null; }
    static List<Dictionary<string, object>> L(Dictionary<string, object> d, string key) {
        List<Dictionary<string, object>> list = new List<Dictionary<string, object>>();
        IEnumerable items = d != null && d.ContainsKey(key) ? d[key] as IEnumerable : null;
        if (items != null && !(items is string)) foreach (object o in items) { Dictionary<string, object> x = o as Dictionary<string, object>; if (x != null) list.Add(x); }
        return list;
    }
    // The first sentence answers "can the wired side reach the Internet"; when the whole text does not fit one line,
    // put the next step on its own line instead of letting a word break across lines.
    static string SplitSentences(string text, Font font, int width) {
        int cut = text.IndexOf("。");
        if (cut < 0 || cut == text.Length - 1 || TextRenderer.MeasureText(text, font).Width <= width) return text;
        return text.Substring(0, cut + 1) + "\n" + text.Substring(cut + 1);
    }
    static string BusyTitle(string mode, string label) {
        if (label == "Update") return "正在更新路由看守…";
        switch (mode) {
            case "Setup": return "正在启用分流…";
            case "Repair": return "正在修复路由看守…";
            case "Restore": return "正在还原设置…";
            case "Renew": return "正在续租网线地址…";
            default: return "正在检查…";
        }
    }
    static string BusyReason(string mode) {
        switch (mode) {
            case "Setup": return "先备份，再建立防火墙阻断和路由。Wi-Fi 不会断开。";
            case "Repair": return "防火墙阻断保持不变。";
            case "Restore": return "完成后，网线可能可以访问公网。";
            case "Renew": return "只续租网线地址，不碰 Wi-Fi。";
            default: return "读取网卡、路由、防火墙和路由看守。";
        }
    }
    // Short result for the footer line; the full message goes to the log.
    static string Outcome(string mode, string label, bool ok) {
        if (label == "Update") return ok ? "路由看守已更新" : "更新路由看守没有完成";
        switch (mode) {
            case "Setup": return ok ? "已启用分流" : "启用分流没有完成";
            case "Repair": return ok ? "路由看守已修复" : "修复路由看守没有完成";
            case "Restore": return ok ? "已还原设置" : "还原设置没有完成";
            case "Renew": return ok ? "网线续租成功" : "网线续租没有完成";
            default: return ok ? "检查完成" : "检查没有完成";
        }
    }

    void ApplyView() {
        SuspendLayout();
        bool busy = busyMode != null;
        bool refreshing = busy && busyMode == "Status" && view == "status";
        bool working = busy && !refreshing;
        Dictionary<string, object> summary = D(status, "Summary");
        string level, head, why, action = "";
        if (working) { level = "neutral"; head = BusyTitle(busyMode, busyLabel); why = BusyReason(busyMode); }
        else if (view == "unknown") { level = "warn"; head = "无法读取状态"; why = unknownReason; action = "Status"; }
        else if (view == "status" && summary != null) { level = S(summary, "Level"); head = S(summary, "Title"); why = S(summary, "Reason"); action = S(summary, "Action"); }
        else { level = "neutral"; head = "正在检查…"; why = BusyReason("Status"); }
        if (busy) action = "";
        primaryAction = action;
        bandIcon.Set(working ? "busy" : level == "neutral" ? "pending" : level, true);
        SetBandColor(Palette.Band(level));
        title.Text = head; title.ForeColor = Palette.Text(level);
        reason.Text = SplitSentences(why ?? "", fBody, ui.Px(ContentWidth - 28 - 32 - 14 - 28)); Reveal(reason, reason.Text.Length > 0);
        primary.Text = action == "Setup" ? "启用分流…" : action == "Repair" ? "修复路由看守" : action == "Adapters" ? "打开网络连接" : "重新检查";
        primary.Fit(); Reveal(primary, action.Length > 0);
        Reveal(progress, busy);

        noticeTitle.Text = opErrorTitle ?? ""; noticeText.Text = opError ?? "";
        Reveal(notice, opError != null && !busy);
        // Retrying is offered for the changes that need no confirmation; enabling and restoring go through their own buttons.
        Reveal(noticeRetry, failedMode == "Renew" || failedMode == "Repair");
        Reveal(noticeLog, !logExpanded);
        Reveal(lastLogLabel, !IsOn(notice));

        recheck.Text = refreshing ? "正在检查…" : "重新检查"; recheck.Fit(); recheck.Enabled = !busy;
        Reveal(recheck, view != "loading" && !working && action != "Status");
        lastCheckLabel.Text = working ? "完成后会重新检查" : lastCheck == DateTime.MinValue ? "" : "上次检查 " + lastCheck.ToString("HH:mm");
        Reveal(lastCheckLabel, lastCheckLabel.Text.Length > 0 && view != "loading");

        RenderChecks(working);
        RenderNics(working);
        bool known = view == "status";
        // While another change is running (for example from a window closed earlier), nothing here may start a second one.
        bool elsewhere = known && B(status, "Busy");
        Reveal(renew, known && !elsewhere && B(status, "Installed") && B(status, "Healthy") && B(status, "WifiConnected"));
        Reveal(restore, known && !elsewhere && B(status, "CanRestore"));
        renew.Enabled = restore.Enabled = !busy;
        Reveal(logPanel, logExpanded);
        logToggle.Text = logExpanded ? "收起日志" : "查看日志"; logToggle.Fit();
        LayoutAll();
        ResumeLayout(true);
        // Keep keyboard focus on something that exists: the action that fixes things, otherwise nothing.
        if (ActiveControl != null && !IsOn(ActiveControl)) ActiveControl = null;
        if (ActiveControl == null && IsOn(primary) && !IsPreview) ActiveControl = primary;
        if ((busy || bandT < 1) && !anim.Enabled) anim.Start();
    }
    CheckRow AddRow(List<CheckRow> rows, bool withIcon) {
        CheckRow row = new CheckRow { Name = NewLabel(this, fBody, Palette.Ink), Detail = NewLabel(this, fBody, Palette.Muted), Role = NewLabel(this, fBody, Palette.Ink) };
        if (withIcon) Controls.Add(row.Icon); else Reveal(row.Icon, false);
        row.Link = NewButton(this, ButtonKind.Link, "更新", fBody, delegate { busyLabel = "Update"; StartJob("Repair"); });
        rows.Add(row); return row;
    }
    void RenderChecks(bool dim) {
        List<Dictionary<string, object>> checks = view == "status" ? L(status, "Checks") : new List<Dictionary<string, object>>();
        if (view != "status") {
            // Placeholder rows keep the layout stable while nothing is known yet.
            foreach (string name in new[] { "防火墙阻断", "网线默认路由", "路由看守" }) {
                Dictionary<string, object> c = new Dictionary<string, object>(); c["Name"] = name; c["State"] = "pending"; c["Detail"] = view == "unknown" ? "未知" : "读取中…"; checks.Add(c);
            }
        }
        // Problems first, then the rest in the backend's order.
        string[] order = { "error", "warn", "ok", "info", "off", "pending" };
        checks = checks.Select((c, i) => new { c, i }).OrderBy(x => Array.IndexOf(order, S(x.c, "State"))).ThenBy(x => x.i).Select(x => x.c).ToList();
        while (checkRows.Count < checks.Count) AddRow(checkRows, true);
        for (int i = 0; i < checkRows.Count; i++) {
            CheckRow row = checkRows[i];
            bool used = i < checks.Count;
            Reveal(row.Icon, used); Reveal(row.Name, used); Reveal(row.Detail, used); Reveal(row.Role, false);
            Reveal(row.Link, used && S(checks[i], "Fix") == "Update" && busyMode == null && !B(status, "Busy"));
            if (!used) continue;
            string state = S(checks[i], "State");
            row.Icon.Set(state, true); row.Icon.Dim = dim;
            row.Name.Text = S(checks[i], "Name");
            row.Detail.Text = S(checks[i], "Detail");
            row.Name.ForeColor = dim ? Palette.Muted : Palette.Ink;
            row.Detail.ForeColor = dim ? Palette.Muted : state == "error" || state == "warn" ? Palette.Text(state) : state == "ok" ? Palette.Ink : Palette.Muted;
        }
    }
    void RenderNics(bool dim) {
        List<Dictionary<string, object>> adapters = view == "status" ? L(status, "Adapters") : new List<Dictionary<string, object>>();
        if (adapters.Count == 0) {
            foreach (string label in new[] { "Wi-Fi", "网线" }) { Dictionary<string, object> a = new Dictionary<string, object>(); a["Label"] = label; a["Pending"] = true; adapters.Add(a); }
        }
        while (nicRows.Count < adapters.Count) AddRow(nicRows, false);
        for (int i = 0; i < nicRows.Count; i++) {
            CheckRow row = nicRows[i];
            bool used = i < adapters.Count;
            Reveal(row.Name, used); Reveal(row.Detail, used); Reveal(row.Link, false);
            if (!used) { Reveal(row.Role, false); continue; }
            Dictionary<string, object> a = adapters[i];
            row.Name.Text = S(a, "Label");
            string name = S(a, "Name"), ip = S(a, "IP");
            if (B(a, "Pending")) row.Detail.Text = view == "unknown" ? "未知" : "读取中…";
            else if (!B(a, "Connected")) row.Detail.Text = (name.Length > 0 ? name + " · " : "") + "未连接";
            else row.Detail.Text = name + " · " + (ip.Length > 0 ? ip : "没有 IPv4 地址");
            row.Role.Text = S(a, "Role");
            row.Role.ForeColor = dim ? Palette.Muted : S(a, "RoleLevel") == "error" ? Palette.Text("error") : Palette.Ink;
            row.Name.ForeColor = dim ? Palette.Muted : Palette.Ink;
            Reveal(row.Role, row.Role.Text.Length > 0);
        }
    }

    void LayoutAll() {
        // Positions below are content coordinates; a scrolled window would offset them, so lay out from the top.
        if (AutoScroll) AutoScrollPosition = Point.Empty;
        int W = ui.Px(ContentWidth), pad = ui.Px(28), iconBig = ui.Px(32), iconSmall = ui.Px(16);
        int textX = pad + iconBig + ui.Px(14), textW = W - textX - pad;
        // Status band: conclusion, what it means right now, and the one action that fixes it.
        int y = ui.Px(24);
        title.MaximumSize = reason.MaximumSize = new Size(textW, 0);
        title.Location = new Point(textX, y);
        bandIcon.Bounds = new Rectangle(pad, y + Math.Max(0, (title.PreferredHeight - iconBig) / 2), iconBig, iconBig);
        y = title.Bottom + ui.Px(4);
        if (IsOn(reason)) { reason.Location = new Point(textX, y); y = reason.Bottom; }
        if (IsOn(primary)) {
            // Line the button's edge up with the first glyph of the title, not with the label's padding.
            int inset = InkOffset(title.Text, fTitle);
            primary.Location = new Point(textX + inset, y + ui.Px(14)); y = primary.Bottom;
        }
        int bandH = y + ui.Px(22);
        band.Bounds = new Rectangle(0, 0, W, bandH);
        progress.Bounds = new Rectangle(0, bandH - ui.Px(3), W, ui.Px(3));
        y = bandH;

        if (IsOn(notice)) {
            int np = ui.Px(14), ni = ui.Px(16), nx = np + ni + ui.Px(10), nw = W - pad * 2;
            noticeTitle.MaximumSize = noticeText.MaximumSize = new Size(nw - nx - np, 0);
            noticeTitle.Location = new Point(nx, np);
            noticeIcon.Bounds = new Rectangle(np, np + (noticeTitle.Height - ni) / 2, ni, ni);
            noticeText.Location = new Point(nx, noticeTitle.Bottom + ui.Px(2));
            noticeNote.MaximumSize = new Size(nw - nx - np, 0);
            noticeNote.Location = new Point(nx, noticeText.Bottom + ui.Px(2));
            int ly = noticeNote.Bottom + ui.Px(2), lx2 = nx - ui.Px(4), bottom = noticeNote.Bottom + np;
            foreach (ActionButton b in new[] { noticeRetry, noticeLog }) {
                if (!IsOn(b)) continue;
                b.Location = new Point(lx2, ly); lx2 = b.Right + ui.Px(8); bottom = b.Bottom + ui.Px(8);
            }
            notice.Bounds = new Rectangle(pad, y + ui.Px(16), nw, bottom);
            y = notice.Bottom;
        }

        // Checks and adapters share one grid: icon, name column, value column.
        int nameX = pad + iconSmall + ui.Px(10), nameW = 0;
        foreach (CheckRow r in checkRows.Concat(nicRows)) if (IsOn(r.Name)) nameW = Math.Max(nameW, r.Name.PreferredWidth);
        int detailX = nameX + nameW + ui.Px(20), detailW = W - detailX - pad;
        y += ui.Px(20);
        // When the checks were read, and the way to read them again, sit on the checks heading.
        checksHeader.Location = new Point(pad, y);
        int right = W - pad, headBottom = checksHeader.Bottom;
        if (IsOn(recheck)) { recheck.Location = new Point(right - recheck.Width, y + (checksHeader.Height - recheck.Height) / 2); right = recheck.Left; headBottom = Math.Max(headBottom, recheck.Bottom); }
        if (IsOn(lastCheckLabel)) lastCheckLabel.Location = new Point(right - lastCheckLabel.Width - (IsOn(recheck) ? 0 : ui.Px(4)), y + (checksHeader.Height - lastCheckLabel.Height) / 2);
        y = headBottom + ui.Px(8);
        foreach (CheckRow r in checkRows) {
            if (!IsOn(r.Name)) continue;
            int linkW = IsOn(r.Link) ? r.Link.Width + ui.Px(4) : 0;
            r.Detail.MaximumSize = new Size(detailW - linkW, 0);
            r.Name.Location = new Point(nameX, y); r.Detail.Location = new Point(detailX, y);
            r.Icon.Bounds = new Rectangle(pad, y + (r.Name.Height - iconSmall) / 2, iconSmall, iconSmall);
            if (IsOn(r.Link)) r.Link.Location = new Point(r.Detail.Right + ui.Px(4), y + (r.Detail.Height - r.Link.Height) / 2);
            y = Math.Max(r.Name.Bottom, r.Detail.Bottom) + ui.Px(10);
        }
        y += ui.Px(10);
        nicHeader.Location = new Point(pad, y); y = nicHeader.Bottom + ui.Px(10);
        foreach (CheckRow r in nicRows) {
            if (!IsOn(r.Name)) continue;
            int roleW = IsOn(r.Role) ? r.Role.PreferredWidth : 0;
            r.Detail.MaximumSize = new Size(Math.Max(ui.Px(60), detailW - roleW - ui.Px(16)), 0);
            r.Name.Location = new Point(nameX, y); r.Detail.Location = new Point(detailX, y);
            if (IsOn(r.Role)) r.Role.Location = new Point(W - pad - roleW, y);
            y = Math.Max(r.Name.Bottom, Math.Max(r.Detail.Bottom, IsOn(r.Role) ? r.Role.Bottom : 0)) + ui.Px(10);
        }
        // Actions that can run right now, set apart from the adapter rows.
        if (IsOn(renew) || IsOn(restore)) {
            y += ui.Px(20);
            if (IsOn(renew)) renew.Location = new Point(pad, y);
            if (IsOn(restore)) restore.Location = new Point(W - pad - restore.Width, y);
            y += restore.Height + ui.Px(6);
        }
        y += ui.Px(14);
        divider.Bounds = new Rectangle(0, y, W, 1);
        y += 1 + ui.Px(10);
        // Footer: the latest action on the left, utility links on the right, the scope note last.
        int lx = W - pad;
        foreach (ActionButton b in new[] { help, openFolder, logToggle }) { b.Location = new Point(lx - b.Width, y); lx = b.Left - ui.Px(6); }
        lastLogLabel.Bounds = new Rectangle(pad, y + (help.Height - fSmall.Height - ui.Px(4)) / 2, Math.Max(ui.Px(40), lx - pad - ui.Px(8)), fSmall.Height + ui.Px(4));
        y = help.Bottom + ui.Px(4);
        if (IsOn(logPanel)) {
            logPanel.Bounds = new Rectangle(pad, y + ui.Px(4), W - pad * 2, ui.Px(112));
            int lineH = TextRenderer.MeasureText("国", logBox.Font).Height;
            logBox.ScrollBars = logBox.Lines.Length * lineH > logBox.ClientSize.Height ? ScrollBars.Vertical : ScrollBars.None;
            y = logPanel.Bottom + ui.Px(10);
        }
        disclaimer.MaximumSize = new Size(W - pad * 2, 0);
        disclaimer.Location = new Point(pad, y); y = disclaimer.Bottom + ui.Px(14);
        // Fit the window to the content; scroll only in the direction the screen is too small.
        Rectangle work = Screen.FromControl(this).WorkingArea;
        int screenW = PreviewScreen.Width > 0 ? PreviewScreen.Width : work.Width;
        int screenH = PreviewScreen.Height > 0 ? PreviewScreen.Height : work.Height;
        int maxW = screenW - (Width - ClientSize.Width), maxH = screenH - (Height - ClientSize.Height) - ui.Px(16);
        if (y <= maxH && W <= maxW) { AutoScroll = false; ClientSize = new Size(W, y); return; }
        bool tall = y > maxH, wide = W + (tall ? SystemInformation.VerticalScrollBarWidth : 0) > maxW;
        AutoScroll = true; AutoScrollMinSize = new Size(W, y);
        ClientSize = new Size(Math.Min(W + (tall ? SystemInformation.VerticalScrollBarWidth : 0), maxW), Math.Min(y + (wide ? SystemInformation.HorizontalScrollBarHeight : 0), maxH));
    }

    // Distance from a label's left edge to the first drawn pixel of its text, so other things can line up with the glyphs.
    static int InkOffset(string text, Font font) {
        if (string.IsNullOrEmpty(text)) return 0;
        Size size = TextRenderer.MeasureText(text, font);
        using (Bitmap b = new Bitmap(Math.Max(1, size.Width), Math.Max(1, size.Height)))
        using (Graphics g = Graphics.FromImage(b)) {
            g.Clear(Color.White);
            TextRenderer.DrawText(g, text, font, Point.Empty, Color.Black, Color.White);
            for (int x = 0; x < b.Width; x++) for (int y = 0; y < b.Height; y++) if (b.GetPixel(x, y).R < 160) return x;
        }
        return 0;
    }
    void SetBandColor(Color target) {
        if (target == bandTo) return;
        bandFrom = band.BackColor; bandTo = target; bandT = 0;
    }
    void Animate() {
        bool busy = busyMode != null;
        if (busy) { progress.Step(); if (bandIcon.Kind == "busy") bandIcon.Spin(); }
        if (bandT < 1) {
            bandT = Math.Min(1, bandT + 16f / 180f);
            float eased = 1 - (1 - bandT) * (1 - bandT);
            band.BackColor = Palette.Blend(bandFrom, bandTo, eased);
            foreach (Control c in band.Controls) c.Invalidate();
        }
        if (!busy && bandT >= 1) anim.Stop();
    }

    // ---------- jobs ----------
    void RunPrimary() {
        if (primaryAction == "Setup") {
            if (!ConfirmDialog.Ask(this, ui, "启用分流", "启用后，网线只能访问 192.168 内网",
                new[] { "防火墙阻断网线访问 192.168 以外的地址和全部 IPv6", "网线 DNS 改为当前 Wi-Fi 的 DNS", "安装开机自动运行的路由看守", "改动前先备份，随时可以还原；Wi-Fi 不会断开" },
                "启用分流", false)) return;
            StartJob("Setup");
        } else if (primaryAction == "Repair") StartJob("Repair");
        else if (primaryAction == "Adapters") OpenNetworkConnections();
        else StartJob("Status");
    }
    void AskRestore() {
        if (!ConfirmDialog.Ask(this, ui, "还原设置", "还原后，网线可以重新访问公网",
            new[] { "删除本工具建立的防火墙规则", "停止并卸载路由看守", "恢复备份里的 DNS、接口开销和路由", "建议先关闭需要固定公网出口的软件" },
            "还原设置", true)) return;
        StartJob("Restore");
    }
    void StartJob(string mode) {
        if (busyMode != null || IsPreview) return;
        string engine;
        try { engine = Engine.Prepare(root, package); }
        catch (IntegrityException ex) { Fail(mode, ex.Message, "程序文件不完整或被改过。请重新解压完整的程序，再点“重新检查”。"); busyLabel = null; return; }
        catch (Exception ex) { Fail(mode, ex.Message, ex.Message); busyLabel = null; return; }
        resultPath = Path.Combine(root, "gui-result-" + Guid.NewGuid().ToString("N") + ".json");
        // Output is not redirected: the backend writes its own log, so closing this window cannot break a change half way.
        ProcessStartInfo si = new ProcessStartInfo(powershell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(engine, "backend.ps1") + "\" -Mode " + mode + " -ResultFile \"" + resultPath + "\"") {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden
        };
        try {
            child = new Process { StartInfo = si };
            busyMode = mode; jobStarted = DateTime.Now; killedForTimeout = false;
            // A re-check keeps the notice about a failed change; a new change replaces it.
            if (mode != "Status") { opError = opErrorTitle = failedMode = failedLabel = null; AddLog(BusyTitle(mode, busyLabel).TrimEnd('…'), false, null); }
            ApplyView();
            child.Start();
        } catch (Exception ex) {
            child = null; busyMode = null; busyLabel = null;
            Fail(mode, "无法启动 PowerShell：" + ex.Message, "请再点一次“重新检查”。仍然失败时，查看日志。");
        }
    }
    // A failure is logged in full. A failed change keeps the last known state and shows a notice;
    // a failed check makes the state unknown, because nothing current can be said.
    void Fail(string mode, string message, string unknownHint) {
        AddLog(message, true, Outcome(mode, busyLabel, false));
        WriteErrorLog(mode, message);
        if (mode != "Status" && view == "status") { opErrorTitle = Outcome(mode, busyLabel, false); opError = message; failedMode = mode; failedLabel = busyLabel; }
        else { view = "unknown"; unknownReason = "现在无法确认网线是否受限。" + unknownHint; }
        ApplyView();
    }
    void Poll() {
        if (child == null) return;
        if (!child.HasExited) {
            if (busyMode == "Status" && !killedForTimeout && (DateTime.Now - jobStarted).TotalSeconds > 90) {
                killedForTimeout = true;
                try { child.Kill(); } catch {}
            }
            return;
        }
        Process done = child; child = null;
        done.WaitForExit();
        int exit = done.ExitCode; done.Dispose();
        string mode = busyMode, label = busyLabel;
        Dictionary<string, object> result = null; string failure = null;
        try {
            if (File.Exists(resultPath)) result = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(resultPath));
            else failure = killedForTimeout ? "检查超过 90 秒没有完成，已停止。" : "没有收到后台结果（退出代码 " + exit + "）。";
        } catch (Exception ex) { failure = "无法读取后台结果：" + ex.Message; }
        try { if (File.Exists(resultPath)) File.Delete(resultPath); } catch {}
        busyMode = null;
        bool ok = false;
        Dictionary<string, object> st = result != null ? D(result, "Status") : null;
        if (result != null) {
            ok = B(result, "Success");
            string message = S(result, "Message");
            if (st != null) {
                status = st; view = "status";
                DateTime t; lastCheck = DateTime.TryParse(S(result, "Time"), out t) ? t : DateTime.Now;
            }
            if (ok) { opError = opErrorTitle = null; AddLog(message, false, mode == "Status" ? null : Outcome(mode, label, true)); }
            else if (st == null) Fail(mode == "Status" || view != "status" ? "Status" : mode, message, "请再点一次“重新检查”。仍然失败时，查看日志。");
            else {
                AddLog(message, true, Outcome(mode, label, false)); WriteErrorLog(mode, message);
                if (mode != "Status") { opErrorTitle = Outcome(mode, label, false); opError = message; failedMode = mode; failedLabel = label; }
            }
        } else {
            Fail(mode, failure, killedForTimeout ? "检查超过 90 秒没有完成，请稍后再点“重新检查”。" : "请再点一次“重新检查”。仍然失败时，查看日志。");
        }
        busyLabel = null;
        // A failed change without a fresh status may have left things half done: read the state again.
        bool refresh = !ok && mode != "Status" && st == null && !autoRefreshAfterFailure;
        ApplyView();
        if (refresh) { autoRefreshAfterFailure = true; StartJob("Status"); return; }
        autoRefreshAfterFailure = false;
        if (selfTestPath != null) SelfTestStep(ok);
    }
    void SelfTestStep(bool ok) {
        selfTestRuns++; selfTestOk &= ok;
        if (selfTestRuns < 3) { StartJob("Status"); return; }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(selfTestPath)));
        SaveClient(this, selfTestPath);
        File.WriteAllText(selfTestPath + ".json", json.Serialize(new { Passed = selfTestOk, ConsecutiveStatusChecks = selfTestRuns, Healthy = B(status, "Healthy"), Title = title.Text, Reason = reason.Text }));
        poll.Stop(); Close();
    }
    // Every entry goes to the log; the footer shows a short outcome for actions and failures only.
    void AddLog(string text, bool error, string footer) {
        logBox.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + (error ? "未完成：" : "") + text + Environment.NewLine);
        if (footer == null) return;
        lastLogLabel.Text = DateTime.Now.ToString("HH:mm") + "  " + footer;
        lastLogLabel.ForeColor = error ? Palette.Text("error") : Palette.Muted;
        tips.SetToolTip(lastLogLabel, text);
    }
    void WriteErrorLog(string mode, string message) {
        try {
            File.WriteAllText(Path.Combine(root, "last-operation-error.txt"), DateTime.Now.ToString("o") + "  " + mode + "  " + message + Environment.NewLine + "后台的完整输出在同一文件夹的 last-operation.log（只有启用、修复、续租、还原会写）。" + Environment.NewLine, Encoding.UTF8);
        } catch {}
    }
    void CleanStaleResults() {
        try {
            if (!Directory.Exists(root)) return;
            foreach (string f in Directory.GetFiles(root, "gui-result-*.json"))
                if ((DateTime.Now - File.GetLastWriteTime(f)).TotalMinutes > 10) File.Delete(f);
        } catch {}
    }
    void OnClosing(object sender, FormClosingEventArgs e) {
        if (busyMode == null || child == null) return;
        if (busyMode == "Status") { try { child.Kill(); } catch {} return; }
        if (!ConfirmDialog.Ask(this, ui, "操作还在进行", "关闭窗口不会中止正在进行的操作", new[] { "完成后结果写入日志；再次打开本工具即可看到当前状态" }, "关闭窗口", false)) e.Cancel = true;
    }
    void OpenFolder() {
        if (!Directory.Exists(root)) { AddLog("这台电脑还没有数据文件夹。", false, "还没有数据文件夹"); ApplyView(); return; }
        Process.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "\"" + root + "\"");
    }
    void OpenHelp() {
        string file = Path.Combine(package, "使用说明.txt");
        if (!File.Exists(file)) { AddLog("找不到使用说明.txt。", true, "找不到使用说明"); ApplyView(); return; }
        Process.Start(Path.Combine(Environment.SystemDirectory, "notepad.exe"), "\"" + file + "\"");
    }
    void OpenNetworkConnections() {
        Process.Start(Path.Combine(Environment.SystemDirectory, "control.exe"), "ncpa.cpl");
    }

    static Icon MakeIcon() {
        using (Bitmap bmp = new Bitmap(32, 32)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Color.Transparent);
                using (GraphicsPath p = Ui.Rounded(new RectangleF(1, 1, 30, 30), 7)) using (SolidBrush b = new SolidBrush(Palette.Accent)) g.FillPath(b, p);
                using (Pen pen = new Pen(Color.White, 3f)) {
                    pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                    g.DrawLine(pen, 7, 16, 13, 16);
                    g.DrawBezier(pen, 13, 16, 18, 16, 19, 9, 25, 9);
                    g.DrawBezier(pen, 13, 16, 18, 16, 19, 23, 25, 23);
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }
    }
    static void SaveClient(Form form, string path) {
        Rectangle client = form.RectangleToScreen(form.ClientRectangle);
        using (Bitmap whole = new Bitmap(form.Width, form.Height)) {
            form.DrawToBitmap(whole, new Rectangle(0, 0, form.Width, form.Height));
            Rectangle crop = Rectangle.Intersect(new Rectangle(client.Left - form.Left, client.Top - form.Top, client.Width, client.Height), new Rectangle(0, 0, whole.Width, whole.Height));
            using (Bitmap part = whole.Clone(crop, whole.PixelFormat)) part.Save(path, ImageFormat.Png);
        }
    }

    // ---------- preview: fictional data, no backend, no file outside the output folder ----------
    static Dictionary<string, object> Check(string key, string name, string state, string detail, string fix = "") {
        Dictionary<string, object> c = new Dictionary<string, object>(); c["Key"] = key; c["Name"] = name; c["State"] = state; c["Detail"] = detail; c["Fix"] = fix; return c;
    }
    static Dictionary<string, object> Nic(string label, string name, string ip, string role, string level) {
        Dictionary<string, object> a = new Dictionary<string, object>(); a["Label"] = label; a["Name"] = name; a["IP"] = ip; a["Connected"] = true; a["Role"] = role; a["RoleLevel"] = level; return a;
    }
    static Dictionary<string, object> FakeStatus(string level, string head, string why, string action, bool installed, bool healthy, bool outdated, object[] nics, params Dictionary<string, object>[] checks) {
        Dictionary<string, object> s = new Dictionary<string, object>();
        Dictionary<string, object> summary = new Dictionary<string, object>();
        summary["Level"] = level; summary["Title"] = head; summary["Reason"] = why; summary["Action"] = action;
        s["Summary"] = summary; s["Checks"] = checks.Cast<object>().ToArray(); s["Adapters"] = nics;
        s["WifiConnected"] = true; s["Installed"] = installed; s["Healthy"] = healthy; s["CanRestore"] = installed; s["GuardOutdated"] = outdated;
        return s;
    }
    void ShowFake(string viewName, Dictionary<string, object> fake, string busy, string failTitle, string failText, bool log) {
        view = viewName; status = fake; busyMode = busy; opErrorTitle = failTitle; opError = failText; logExpanded = log;
        lastCheck = DateTime.Now;
        if (viewName == "unknown") unknownReason = "现在无法确认网线是否受限。程序文件不完整或被改过。请重新解压完整的程序，再点“重新检查”。";
        bandT = 1; bandFrom = bandTo = Palette.Band("neutral");
        ApplyView();
        bandT = 1; band.BackColor = bandTo;
        ActiveControl = null;
    }
    static List<string> Problems(Control rootControl) {
        List<string> problems = new List<string>();
        Action<Control> walk = null;
        walk = delegate(Control parent) {
            List<Control> visible = parent.Controls.Cast<Control>().Where(c => c.Visible).ToList();
            foreach (Control c in visible) {
                Label l = c as Label;
                if (l != null && l.Text.Length > 0) {
                    Size need = l.AutoSize ? l.GetPreferredSize(l.MaximumSize.Width > 0 ? new Size(l.MaximumSize.Width, 0) : Size.Empty) : TextRenderer.MeasureText(l.Text, l.Font);
                    if (!l.AutoEllipsis && (need.Width > l.Width + 1 || need.Height > l.Height + 1)) problems.Add("clipped: \"" + l.Text + "\" " + l.Size + " needs " + need);
                    if (l.AutoEllipsis && TextRenderer.MeasureText(l.Text, l.Font).Width > l.Width) problems.Add("ellipsis: \"" + l.Text + "\"");
                }
                Rectangle area = parent is ScrollableControl && ((ScrollableControl)parent).AutoScroll ? ((ScrollableControl)parent).DisplayRectangle : new Rectangle(Point.Empty, parent.ClientSize);
                if (c.Right > area.Right || c.Bottom > area.Bottom) problems.Add("outside parent: " + c.GetType().Name + " \"" + c.Text + "\" " + c.Bounds);
                foreach (Control o in visible) {
                    if (o == c || o is ProgressStrip || c is ProgressStrip || o.GetHashCode() < c.GetHashCode()) continue;
                    if (c.Bounds.IntersectsWith(o.Bounds)) problems.Add("overlap: \"" + c.Text + "\" " + c.Bounds + " / \"" + o.Text + "\" " + o.Bounds);
                }
                walk(c);
            }
        };
        walk(rootControl);
        return problems;
    }
    // Preview only: pretend the screen's working area has this size, to exercise the scrolling layout on a large monitor.
    static Size PreviewScreen;
    static void RunPreview(string folder, float[] scales) {
        Directory.CreateDirectory(folder);
        StringBuilder report = new StringBuilder();
        foreach (float scale in scales) {
            using (SplitWindow w = new SplitWindow(new string[0], scale, true)) {
                w.StartPosition = FormStartPosition.Manual; w.Location = new Point(-6000, -6000); w.ShowInTaskbar = false;
                w.Show(); Application.DoEvents();
                string tag = "@" + (int)(scale * 100);
                Dictionary<string, object> fw = Check("firewall", "防火墙阻断", "ok", "只放行 192.168 内网，IPv6 全部阻断");
                Dictionary<string, object> fwAlias = Check("firewall", "防火墙阻断", "ok", "只放行 192.168 内网，IPv6 全部阻断 · 仅限“以太网”");
                Dictionary<string, object> rt = Check("routes", "网线默认路由", "ok", "0 条");
                Dictionary<string, object> gd = Check("guard", "路由看守", "ok", "运行中");
                Dictionary<string, object> other = Check("other", "其他接口", "info", "Tailscale：不在本工具控制范围");
                object[] nicsOk = { Nic("Wi-Fi", "WLAN", "172.20.10.5", "公网出口", "ok"), Nic("网线", "以太网", "192.168.31.47", "只能访问 192.168 内网", "ok") };
                object[] nicsOpen = { Nic("Wi-Fi", "WLAN", "172.20.10.5", "", "ok"), Nic("网线", "以太网", "192.168.31.47", "公网出口 · 未限制", "error") };
                object[] nicsDock = { Nic("网线 2", "USB 以太网", "192.168.31.88", "未限制", "error"), Nic("Wi-Fi", "WLAN", "172.20.10.5", "公网出口", "ok"), Nic("网线", "以太网", "192.168.31.47", "只能访问 192.168 内网", "ok") };
                string okWhy = "公网走 Wi-Fi，网线只能访问 192.168.0.0/16。";
                var states = new List<Tuple<string, Action>>();
                states.Add(Tuple.Create<string, Action>("01-loading", () => w.ShowFake("loading", null, "Status", null, null, false)));
                states.Add(Tuple.Create<string, Action>("02-ok", () => w.ShowFake("status", FakeStatus("ok", "分流已生效", okWhy, "", true, true, false, nicsOk, fw, rt, gd, other), null, null, null, false)));
                states.Add(Tuple.Create<string, Action>("03-ok-update", () => w.ShowFake("status", FakeStatus("ok", "分流已生效", okWhy, "", true, true, true, nicsOk, fwAlias, rt, gd, Check("guard-version", "看守版本", "info", "运行中的是旧版本", "Update"), other), null, null, null, false)));
                states.Add(Tuple.Create<string, Action>("04-not-enabled-exposed", () => w.ShowFake("status", FakeStatus("error", "尚未启用分流", "网线现在可以直接访问公网。", "Setup", false, false, false, nicsOpen, Check("firewall", "防火墙阻断", "off", "未建立"), Check("routes", "网线默认路由", "error", "1 条"), Check("guard", "路由看守", "off", "未安装")), null, null, null, false)));
                states.Add(Tuple.Create<string, Action>("05-guard-down", () => w.ShowFake("status", FakeStatus("warn", "路由看守没有运行", "防火墙仍在阻断，网线暂时不会访问公网。", "Repair", true, false, false, nicsOk, fw, Check("routes", "网线默认路由", "warn", "1 条"), Check("guard", "路由看守", "warn", "没有运行"), other), null, null, null, false)));
                states.Add(Tuple.Create<string, Action>("06-other-wired", () => w.ShowFake("status", FakeStatus("error", "“USB 以太网”可以直接上公网", "先在系统里断开它。要长期使用，请还原设置后重新启用。", "Adapters", true, false, false, nicsDock, Check("other-wired", "网线 2", "error", "不在防火墙范围内，有默认路由"), fwAlias, rt, gd, other), null, null, null, false)));
                states.Add(Tuple.Create<string, Action>("07-unknown", () => w.ShowFake("unknown", null, null, null, null, false)));
                states.Add(Tuple.Create<string, Action>("08-busy-setup", () => w.ShowFake("status", FakeStatus("error", "尚未启用分流", "网线现在可以直接访问公网。", "Setup", false, false, false, nicsOpen, Check("firewall", "防火墙阻断", "off", "未建立"), Check("routes", "网线默认路由", "error", "1 条"), Check("guard", "路由看守", "off", "未安装")), "Setup", null, null, false)));
                states.Add(Tuple.Create<string, Action>("09-op-failed", () => w.ShowFake("status", FakeStatus("ok", "分流已生效", okWhy, "", true, true, false, nicsOk, fw, rt, gd, other), null, "网线续租没有完成", "网线续租命令失败，输出保存在数据文件夹的 dhcp-renew-20261019-0948.txt。", false)));
                states.Add(Tuple.Create<string, Action>("12-op-failed-log", () => { w.ShowFake("status", FakeStatus("ok", "分流已生效", okWhy, "", true, true, false, nicsOk, fw, rt, gd, other), null, "网线续租没有完成", "网线续租命令失败，输出保存在数据文件夹的 dhcp-renew-20261019-0948.txt。", true); w.failedMode = "Renew"; w.ApplyView(); }));
                foreach (var st in states) {
                    w.logBox.Clear(); w.lastLogLabel.Text = "";
                    if (st.Item1 == "02-ok") w.AddLog("网线 DHCP 续租成功：默认路由 0 条，看守正常，Wi-Fi 仍然连接。", false, "网线续租成功");
                    if (st.Item1 == "07-unknown") w.AddLog("backend.ps1 和构建时不一致，可能被改过。请重新解压完整的程序，或重新运行 build.ps1。", true, "检查没有完成");
                    if (st.Item1 == "09-op-failed" || st.Item1 == "12-op-failed-log") { w.AddLog("正在续租网线地址", false, null); w.AddLog("网线续租命令失败，输出保存在数据文件夹的 dhcp-renew-20261019-0948.txt。", true, "网线续租没有完成"); w.failedMode = "Renew"; }
                    st.Item2();
                    w.Refresh(); Application.DoEvents();
                    SaveClient(w, Path.Combine(folder, st.Item1 + tag + ".png"));
                    foreach (string p in Problems(w)) report.AppendLine(st.Item1 + tag + "  " + p);
                    // Too tall for the screen: the window scrolls; capture the bottom as well. The scroll bar itself is window chrome and is not in the capture.
                    if (w.AutoScroll) {
                        w.AutoScrollPosition = new Point(0, w.AutoScrollMinSize.Height);
                        w.Refresh(); Application.DoEvents();
                        SaveClient(w, Path.Combine(folder, st.Item1 + tag + "-scrolled.png"));
                        w.AutoScrollPosition = Point.Empty;
                    }
                }
                foreach (bool danger in new[] { false, true }) {
                    ConfirmDialog d = danger
                        ? new ConfirmDialog(w.ui, "还原设置", "还原后，网线可以重新访问公网", new[] { "删除本工具建立的防火墙规则", "停止并卸载路由看守", "恢复备份里的 DNS、接口开销和路由", "建议先关闭需要固定公网出口的软件" }, "还原设置", true)
                        : new ConfirmDialog(w.ui, "启用分流", "启用后，网线只能访问 192.168 内网", new[] { "防火墙阻断网线访问 192.168 以外的地址和全部 IPv6", "网线 DNS 改为当前 Wi-Fi 的 DNS", "安装开机自动运行的路由看守", "改动前先备份，随时可以还原；Wi-Fi 不会断开" }, "启用分流", false);
                    using (d) {
                        d.StartPosition = FormStartPosition.Manual; d.Location = new Point(-6000, -6000); d.Show(); Application.DoEvents();
                        string name = (danger ? "11-confirm-restore" : "10-confirm-setup") + tag;
                        SaveClient(d, Path.Combine(folder, name + ".png"));
                        foreach (string p in Problems(d)) report.AppendLine(name + "  " + p);
                        d.Close();
                    }
                }
                w.Close();
            }
        }
        File.WriteAllText(Path.Combine(folder, "layout-report.txt"), report.Length == 0 ? "no clipping, overflow or overlap found" + Environment.NewLine : report.ToString(), Encoding.UTF8);
    }

    [STAThread] public static int Main(string[] args) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length > 1 && args[0] == "--preview") {
            List<string> rest = args.Skip(2).ToList();
            int at = rest.IndexOf("--screen");
            if (at >= 0 && at + 1 < rest.Count) { string[] wh = rest[at + 1].Split('x'); PreviewScreen = new Size(int.Parse(wh[0]), int.Parse(wh[1])); rest.RemoveRange(at, 2); }
            float[] scales = rest.Count > 0 ? rest.Select(a => float.Parse(a, System.Globalization.CultureInfo.InvariantCulture)).ToArray() : new[] { 1f, 1.25f, 1.5f, 1.75f };
            RunPreview(args[1], scales);
            return 0;
        }
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += delegate(object s, System.Threading.ThreadExceptionEventArgs e) {
            MessageBox.Show("出现意外错误：" + e.Exception.Message, "双网分流", MessageBoxButtons.OK, MessageBoxIcon.Error);
        };
        Application.Run(new SplitWindow(args));
        return 0;
    }
}
