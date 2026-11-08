# MacBook Air (2014) WiFi Fix — FydeOS / ChromeOS 5GHz

> **How this was solved:** with WorkBuddy + DeepSeek V4.1 Flash, plus GitHub search and
> search-enabled MCP tools. It took the better part of 5 hours, so I'm posting it here
> so the next person — or the next AI — can just copy it.

**English** | [中文说明见下方](#中文说明)

---

## What this fixes

On a **MacBook Air 2014 (MacBookAir6,2)** running **FydeOS**, the built-in Broadcom
**BCM4360** (`14e4:43a0`, `wl` driver) behaves like this:

- 5GHz networks **do not appear** in the WiFi list at all
- The machine **does not auto-connect** to a saved 5GHz network after boot
- 2.4GHz works fine — which makes it look like a hardware or antenna problem
- `wpa_cli scan_results` returns **0 entries** even though the APs are clearly there

It is not a hardware fault, and it is not a missing driver. It is a single integer in
the driver that makes `wpa_supplicant`'s scan request invalid.

---

## Root cause

```
wl driver  ->  max_scan_ie_len = 0
```

`wpa_supplicant` 2.11 (the version shipped with FydeOS) **always** appends a 22-byte
extra IE to its scan request — Extended Capabilities plus MBO/OCE. The kernel's
`nl80211_trigger_scan()` compares the IE length against the driver's advertised
`max_scan_ie_len` and rejects the whole request with `-EINVAL`.

So the chain breaks like this:

```
wpa_supplicant scan  --(-EINVAL)-->  never learns any BSS
                                          |
                                          v
                              shill sees no 5GHz APs
                                          |
                                          v
                        no auto-connect, empty UI list
```

`max_scan_ie_len = 0` means the driver accepts **zero** bytes of extra IE. Even
disabling OCE (`oce=0`) is not enough, because that only removes 9 of the 22 bytes —
13 are still left over and the request is still rejected.

---

## The fix

`iw dev wlan0 scan` builds its scan request **without** any extra IE (`ie_len = 0`),
so the driver accepts it. And crucially, the results are written into the **same BSS
table that `wpa_supplicant` and `shill` read from**.

So instead of patching `wpa_supplicant` (there is no compiler on the device), we just
keep feeding scan results in from `iw`:

```
iw dev wlan0 scan  -->  BSS table  -->  shill finds the saved 5GHz profile
                                    -->  auto-connects
```

That's the whole trick. A background loop runs `iw dev wlan0 scan` every 15 s for the
first 3 minutes after boot, then every 45 s in steady state.

**No** patched `wpa_supplicant`. **No** `ap_scan=2`. **No** `oce=0`. **No** recompiling
anything.

---

## Verified result

After two real reboots, with only the internal card in use:

- `wlan0` auto-connects to the saved 5GHz network on boot
- DHCP address assigned, internet reachable, SSH reachable
- `wpa_supplicant` BSS table went from **0 to 21+** entries
- shill lists **7 different 5GHz** networks as available services
- The 5GHz networks now show up in the WiFi UI

---

## Install

```bash
# 1. check whether you actually have this bug (read-only)
sudo bash diagnose.sh

# 2. if max_scan_ie_len = 0, install
sudo bash install.sh

# 3. reboot and confirm
```

`install.sh` puts the scripts in `/usr/local/bin` (which lives on the stateful
partition, so it survives updates) and installs the boot hook described below.

### Requirements

- FydeOS / ChromeOS with `iw` available at `/usr/sbin/iw`
- Root shell
- Developer mode (you need to write to `/usr/local` and `/usr/share/hwtuner-script`)

---

## How it survives reboots

`/etc/init` is read-only on FydeOS, so you can't just add a service. The trick is
that the `fydeos-collect-log` job runs `hwtuner --info` on every boot, and
`/usr/bin/hwtuner` is a **symlink into `/usr/share/hwtuner-script/`**, which is
writable.

So we replace that script with a wrapper that starts our stuff first, then `exec`s the
original:

```
boot
 └─ fydeos-collect-log job
     └─ hwtuner --info
         └─ /usr/share/hwtuner-script/hwtuner        <- our wrapper
             ├─ /usr/local/bin/fydeos-sshd.sh
             │   ├─ fydeos-wifi-keepalive.sh   (the 5GHz feeder)
             │   └─ sshd
             └─ exec hwtuner.orig  --info         <- original behaviour preserved
```

### ⚠️ You must lock the wrapper

`fydeos-scripts-updater` runs on `shill-connected` and will happily overwrite
`/usr/share/hwtuner-script/hwtuner` from a remote copy. Lock it:

```bash
chattr +i /usr/share/hwtuner-script/hwtuner
lsattr /usr/share/hwtuner-script/hwtuner
# expect: ----i---------e-------
```

`install.sh` does this for you. Verified to still be locked after a reboot.

---

## Files

| File | Installed to | Purpose |
|---|---|---|
| `scripts/fydeos-wifi-keepalive.sh` | `/usr/local/bin/` | the 5GHz scan feeder |
| `scripts/fydeos-sshd.sh` | `/usr/local/bin/` | boot entry point; starts feeder + sshd |
| `scripts/hwtuner-wrapper.sh` | `/usr/share/hwtuner-script/hwtuner` | the actual boot hook |
| `diagnose.sh` | — | read-only check, run this first |
| `install.sh` | — | installer |
| `uninstall.sh` | — | revert |

---

## Things that did NOT work

Worth recording so nobody else spends hours on them:

| Attempt | Why it failed |
|---|---|
| `oce=0` in wpa_supplicant config | Removes only 9 of the 22 bytes; 13 remain, still `-EINVAL` |
| WEXT backend (`-D wext`) | Not compiled into the FydeOS build of wpa_supplicant |
| `ap_scan=2` direct connect | Works for connecting, but the UI list stays empty (no scan results) |
| Patching + recompiling wpa_supplicant | No `gcc`/`cc`/`clang`/`make` on the device |
| `iwlist scan` | Deprecated WEXT tool, unreliable on `wl` |

---

## Gotchas worth knowing

- **Absolute paths are mandatory.** `iw` is in `/usr/sbin` and `ip` in `/bin`. The
  minimal `PATH` during early boot does **not** include `/usr/sbin`, so a bare `iw`
  will silently fail in the boot hook.
- **Don't use `pkill -f "scriptname.sh"`** to kill these. Your own SSH command line
  contains that string, so `pkill -f` matches your own session and kills it. Match by
  PID instead:
  ```bash
  ps -eo pid,args | awk '$2 ~ /bash$/ && $3 == "/usr/local/bin/fydeos-wifi-keepalive.sh" {print $1}'
  ```
- **Running `iw dev wlan0 scan` by hand** will flush and refill the BSS cache. While
  connected you'll mostly see same-channel APs. The feeder refills it continuously, so
  this is harmless.
- **`/var` is a tmpfs** (well, an encrypted stateful mount) — anything you need to
  survive a reboot belongs in `/usr/local` or `/mnt/stateful_partition/`.

---

## Tested on

| | |
|---|---|
| Machine | MacBook Air 2014 (`MacBookAir6,2`) |
| WiFi | Broadcom BCM4360 `14e4:43a0`, `wl` driver |
| OS | FydeOS (Chromium OS based), kernel 5.4 |
| wpa_supplicant | 2.11 |

Other Broadcom `wl`-based Macs likely have the same `max_scan_ie_len = 0` limitation.
Run `diagnose.sh` to check — if the value is not 0, this fix does not apply.

---

## License

MIT. Copy it, paste it, feed it to your AI. That's the point.

---

<a id="中文说明"></a>
## 中文说明

### 解决了什么

**MacBook Air 2014** 装 **FydeOS** 后，内置的 Broadcom **BCM4360** 无线网卡：

- 5GHz 网络在 WiFi 列表里**根本不显示**
- 开机**不会自动连接**已保存的 5GHz 网络
- 2.4GHz 一切正常，所以很容易误判成硬件坏了或者天线问题
- `wpa_cli scan_results` 返回 **0 条**，但 AP 明明就在那儿

不是硬件坏，也不是缺驱动。是驱动里一个整数让 `wpa_supplicant` 的扫描请求变成了非法请求。

### 根本原因

```
wl 驱动  ->  max_scan_ie_len = 0
```

FydeOS 自带的 `wpa_supplicant` 2.11 在发起扫描时，**总是**附带 22 字节的额外 IE
（Extended Capabilities + MBO/OCE）。内核 `nl80211_trigger_scan()` 会拿这个长度和驱动
声明的 `max_scan_ie_len` 比较，超出就直接 `-EINVAL` 拒绝整个请求。

于是链路这样断掉：

```
wpa_supplicant 扫描  --(-EINVAL)-->  永远学不到任何 BSS
                                        |
                                        v
                            shill 看不到 5GHz AP
                                        |
                                        v
                          不自动连接，界面列表空白
```

`max_scan_ie_len = 0` 意味着驱动**一个字节**的额外 IE 都不接受。所以连关掉 OCE
（`oce=0`）都没用 —— 那只去掉 22 字节里的 9 个，还剩 13 个，照样被拒。

### 解决办法

`iw dev wlan0 scan` 构造扫描请求时**不带**额外 IE（`ie_len = 0`），驱动接受。
关键在于：扫描结果会写进 **`wpa_supplicant` 和 `shill` 共用的那张 BSS 表**。

所以不用去改 `wpa_supplicant`（设备上根本没有编译器），只要用 `iw` 不停地喂扫描结果：

```
iw dev wlan0 scan  -->  BSS 表  -->  shill 找到已保存的 5GHz 配置
                              -->  自动连上
```

就这么简单。后台循环在开机后 3 分钟内每 15 秒扫一次，之后稳态每 45 秒一次。

**不需要**改版 `wpa_supplicant`，**不需要** `ap_scan=2`，**不需要** `oce=0`，**不需要**编译任何东西。

### 实测结果

两次真实重启，只用内置网卡：

- 开机 `wlan0` 自动连上已保存的 5GHz 网络
- 分配到 IP，外网通，SSH 可达
- `wpa_supplicant` 的 BSS 表从 **0 条变成 21+ 条**
- shill 里能看到 **7 个不同的 5GHz** 网络
- 界面 WiFi 列表里 5GHz 正常显示

### 安装

```bash
sudo bash diagnose.sh    # 先确认是不是这个毛病（只读，不改任何东西）
sudo bash install.sh     # 如果 max_scan_ie_len = 0，就装
# 重启验证
```

### 为什么能扛住重启

FydeOS 的 `/etc/init` 是只读的，加不了服务。但 `fydeos-collect-log` 这个 job 每次开机
都会执行 `hwtuner --info`，而 `/usr/bin/hwtuner` 是个**软链接，指向可写的
`/usr/share/hwtuner-script/`**。

所以把那个脚本换成 wrapper：先拉起我们的东西，再 `exec` 原版，原功能不受影响。

```
开机
 └─ fydeos-collect-log job
     └─ hwtuner --info
         └─ /usr/share/hwtuner-script/hwtuner        <- 我们的 wrapper
             ├─ /usr/local/bin/fydeos-sshd.sh
             │   ├─ fydeos-wifi-keepalive.sh   (5GHz 喂养器)
             │   └─ sshd
             └─ exec hwtuner.orig  --info         <- 原版行为保留
```

### ⚠️ 必须锁住 wrapper

`fydeos-scripts-updater` 会在 `shill-connected` 时运行，会用远端版本覆盖
`/usr/share/hwtuner-script/hwtuner`。所以必须：

```bash
chattr +i /usr/share/hwtuner-script/hwtuner
lsattr /usr/share/hwtuner-script/hwtuner
# 应该是：----i---------e-------
```

`install.sh` 会自动做这一步。实测重启后锁依然在。

### 试过但没用的方案

| 尝试 | 为什么不行 |
|---|---|
| `oce=0` | 只去掉 22 字节里的 9 个，还剩 13 个，照样 `-EINVAL` |
| WEXT 后端（`-D wext`） | FydeOS 编译 wpa_supplicant 时没包含 |
| `ap_scan=2` 直连 | 能连上，但界面列表仍然空（没有扫描结果） |
| 改代码重编 wpa_supplicant | 设备上没有 `gcc`/`cc`/`clang`/`make` |
| `iwlist scan` | 已废弃的 WEXT 工具，`wl` 驱动上不可靠 |

### 几个坑

- **必须用绝对路径**。`iw` 在 `/usr/sbin`、`ip` 在 `/bin`。开机早期的最小 `PATH`
  **不含** `/usr/sbin`，直接写 `iw` 会静默失败。
- **不要用 `pkill -f "脚本名.sh"`** 杀进程。你自己的 SSH 命令行里就含这个字符串，
  `pkill -f` 会匹配到自己，把当前会话杀掉。要按 PID 精确匹配：
  ```bash
  ps -eo pid,args | awk '$2 ~ /bash$/ && $3 == "/usr/local/bin/fydeos-wifi-keepalive.sh" {print $1}'
  ```
- **手动跑 `iw dev wlan0 scan`** 会清空并重灌 BSS 缓存。连接状态下扫到的大多是同信道
  AP。喂养器会持续补回，所以无害。
- **`/var` 是内存盘**，需要跨重启保留的东西放 `/usr/local` 或 `/mnt/stateful_partition/`。

### 实测环境

| | |
|---|---|
| 机器 | MacBook Air 2014（`MacBookAir6,2`） |
| 网卡 | Broadcom BCM4360 `14e4:43a0`，`wl` 驱动 |
| 系统 | FydeOS（基于 Chromium OS），内核 5.4 |
| wpa_supplicant | 2.11 |

其他用 Broadcom `wl` 驱动的 Mac 大概率也是同样的 `max_scan_ie_len = 0` 限制。
先跑 `diagnose.sh` 确认 —— 如果那个值不是 0，这个方案就不适用。

### 许可

MIT。随便抄，随便喂给 AI，本来就是为这个发的。
