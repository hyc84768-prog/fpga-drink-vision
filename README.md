# 工程说明

本工程基于安路 HX1P35A 开发板和 PH1P35MDG324 FPGA，实现 MIPI 摄像头采集、视频缓存、图像处理和 HDMI 输出，以五类饮料现场录样与分类识别为主要应用，同时提供红色目标跟踪、运动检测和图像算法展示。

## 文件目录

| 目录 | 内容 |
|---|---|
| user_source | 完整 RTL、安路 IP、相机配置和引脚约束 |
| td_project | 唐朝工程、时钟约束、综合与布局布线运行配置，以及本次构建数据库 |
| bitstream | 已通过路由后时序检查的 drink_vision.bit |
| scripts | 工程路径准备、综合、布局布线及最终签核脚本 |
| tests | 21 组仿真测试、参考数据和运行脚本 |
| reports | 资源、路由后时序、跨时钟域检查与仿真结果 |
| docs | 系统设计、操作和验收说明 |
| assets | 饮料类别定义和赛事标识素材 |

## 打开工程

1. 完整解压本压缩包，建议放在较短的英文路径，例如 D:/FPGA_DrinkVision。
2. 在工程根目录运行 `powershell -ExecutionPolicy Bypass -File scripts/prepare_project.ps1`，将工程定位到实际解压目录。
3. 使用 Tang Dynasty 6.2.168116 打开 `td_project/camera_to_dsi_display.al`。器件为 PH1P35MDG324，速度等级为 -3，顶层为 design_top_wrapper。
4. 可直接使用 `bitstream/drink_vision.bit` 进行 SRAM 试运行或配置 Flash 编程。

## 构建与仿真

在工程根目录依次执行：

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_all.ps1
powershell -ExecutionPolicy Bypass -File scripts/run_syn.ps1
powershell -ExecutionPolicy Bypass -File scripts/run_phy.ps1
powershell -ExecutionPolicy Bypass -File scripts/run_signoff.ps1
```

默认 TD 路径为 D:/anlu/bin/td_commands_prompt.exe，ModelSim 路径为 D:/modelsim1/win64/vsim.exe。安装位置不同时，仿真脚本通过 `-ModelSimExe` 指定 vsim.exe，构建脚本通过 `-TdExe` 指定 td_commands_prompt.exe。厂商加密 IP 需要对应安路软件环境。

## 演示操作

KEY1 切换饮料识别、红色动态识别和图像算法三组。KEY2 选择项目，KEY3 确认/采样/发起识别，KEY4 返回或取消。详细操作见 docs/操作与验收.md。

饮料类别为营养快线、焰焙、美汁源、百事可乐和雪碧。首次上电完成白平衡、背景和三视角样本录入，再按确认键识别。样本在 RAM 中保存，断电或硬复位后重新录入；程序可以固化到配置 Flash，以实现上电启动。

资源和时序结果见 reports/verification_summary.json 及原始报告。屏幕构建标识为 V1035。文件校验见 SHA256SUMS.txt。
