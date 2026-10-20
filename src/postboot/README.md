# 重启后一次性审计源码

这里是重启后一次性审计的检查脚本和用户入口，供审查和手动部署参考，不是独立安装器。GUI 的启用只安装持续运行的路由看守，不会自动安装这个审计任务。

check-after-boot.ps1 从 C:\ProgramData\WifiLanSplit\PostBoot\config.json 读取本机配置，调用 Engine/backend.ps1 和 network-core.ps1 的 Status；该 Engine 是部署时的后端副本。

配置字段：TaskName、MachineGuid、EthernetGuid、WifiGuid、ArmedAt、ArmedBootTicks（启动时间 UTC ticks 字符串）、Completed（布尔）、WaitSeconds（600）、IntervalSeconds（10）、RequiredStableSamples（3）。机器字段必须由目标电脑生成，不能复用本机备份。部署任务要求 SYSTEM/最高权限、BootTrigger 延迟 PT30S、最长运行 15 分钟，文件夹仅 SYSTEM/管理员可写；任务安装与配置生成目前是部署步骤，未提供通用安装命令。

普通运行仅在启动时间改变且 Completed=false 时进入正式检查；-Preflight 允许当前开机预检，但不消耗待重启状态。检查任务/进程是否本次启动后运行、防火墙覆盖、心跳、有线默认路由为 0、默认路由仅 Wi-Fi、三个代表性公网地址选路，并用绑定 Wi-Fi IPv4 的直连 HTTPS 探测复核源地址。检查不会修复网络；会写日志、报告并在正式完成后禁用自己的审计任务。

“查看重启检查结果.cmd”打开报告；“取消重启自动检查.cmd”删除一次性审计任务，不修改持续看守或网络规则。取消属于管理动作，代码审查时无需运行。