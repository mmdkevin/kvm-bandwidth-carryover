# KVM Bandwidth Carryover

**Virtualizor KVM traffic quota carry-over · Application version 2.0.2**

[English guide](#english) | [راهنمای فارسی](#persian)

Keep a VPS's unused traffic allowance when its usage counter resets. Manage installation, upgrades, checks, logs, and backups from one terminal menu.

<p dir="rtl">این برنامه کمک می‌کند با ریست‌شدن مصرف ترافیک، حجم باقی‌ماندهٔ مشتری از بین نرود و سهمیهٔ کامل قبلی دوباره در اختیار او قرار نگیرد.</p>

---

<a name="english"></a>

## English

[How it works](#en-how) · [Installation and upgrade](#en-install) · [Menu](#en-menu) · [Commands](#en-commands) · [Status and troubleshooting](#en-status) · [FAQ](#en-faq)

<a name="en-how"></a>

### What does this tool do?

This tool is for VPS providers who sell a traffic allowance that should remain available until the customer uses it up. It adjusts the **Bandwidth quota in Virtualizor** after an observed usage reset.

For example, a customer has a 5,000 GB allowance and has used 4,300 GB. Their remaining allowance is 700 GB. If Virtualizor resets the usage counter, leaving the quota at 5,000 GB would give them that full allowance again. This tool replaces the quota with the remaining 700 GB.

| Stage | Used traffic | Panel quota | Remaining allowance |
|---|---:|---:|---:|
| Before the reset | 4,300 GB | 5,000 GB | 700 GB |
| After the reset, before correction | 0 GB | 5,000 GB | The panel shows a renewed 5,000 GB allowance |
| After correction | 0 GB | **700 GB** | **700 GB** |

If the VPS has already used 20 GB after the reset, the corrected result is **20 GB used out of 700 GB**, leaving **680 GB**. The tool does not refund that new usage.

### How a check works

1. Read the local KVM VPS list, quotas, and reported usage through the locally installed Virtualizor SDK.
2. Compare each VPS's reported usage with its last saved value.
3. Treat **every observed decrease in usage as a reset**, regardless of its date or cause.
4. Replace the quota with the unused allowance from the previous observation, accounting for quota edits and any saved fractional adjustment.
5. Save the result and an operation record so an interrupted write can be reconciled on a later check.

For whole-GB examples without a fractional adjustment:

```text
New quota = previous quota - previous used traffic + operator quota change
```

The new quota **replaces** the old quota. It is not added to it.

**The tool only writes the Bandwidth quota.** It does not issue Suspend, Unsuspend, network-link, firewall, speed-change, VM shutdown, or Reset Bandwidth commands. Traffic enforcement remains a Virtualizor setting. In particular, the tool does not enable `Bandwidth suspend` for you.

### Operating rule and limitations

**Do not manually reset usage while this tool is managing the VPS.** It does not distinguish a manual reset from a periodic reset. A manual reset, an API-triggered reset, or a downward statistics correction can all be treated as a reset if they lower the observed usage.

This is a polling tool using **Virtualizor's reported usage**, not an independent packet counter:

- If usage resets and grows back to the previous value or higher before the next observation, that reset is not detected.
- The panel's own calculation delay and the interval between observations can leave end-of-period usage unaccounted for.
- Consumption that was reset before the tool's initial enrollment cannot be recovered from the current counter.
- It does not create a new monthly traffic package, process invoices, or decide what a customer has purchased.

<a name="en-install"></a>

### Requirements

- Root access to the main host running Virtualizor and the local KVM guests.
- Python 3.9 or newer and an active `crond` service.
- The installed Virtualizor PHP executable and SDK at their standard paths.
- `curl` and Bash for the download command below.

The current integration targets the AlmaLinux 9 / Virtualizor KVM setup used during development. The bridge handles **local KVM VPSs on the master host (`serid=0`)**. Slave nodes, other hypervisors, and other layouts are not covered by this release.

No additional Python packages are required. No API key needs to be pasted into the script: it reads the local panel configuration.

### First installation

Run this on the main host as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh)
```

Choose **1 — Install / Upgrade**.

The installer checks the package and runs isolated tests before enabling its Cron. It saves the current quota and usage of each eligible VPS as the starting point. Initial enrollment does not reduce quotas or reset usage.

On a fresh installation, automatic checks are **enabled every minute**. Closing the menu or SSH session does not stop them.

For installation without an interactive menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh) install
```

### Upgrade an existing installation

If the managed command is already installed:

```bash
kvm-bw upgrade
```

To upgrade the older installation that does not yet have `kvm-bw`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh) upgrade
```

Upgrade preserves the existing accounting history and policy. It takes a backup before replacing the application files. An enabled schedule stays enabled; a paused schedule stays paused. **Do not delete the saved state to make an upgrade run.**

An installer menu showing `installed: legacy` means an older version of **this tool** is installed. It is not the Virtualizor version. Opening a newly downloaded menu does not itself upgrade the installed application; select option 1 or run the upgrade command.

<a name="en-menu"></a>

### Interactive menu

After installation, run:

```bash
kvm-bw
```

| Option | What it does |
|---|---|
| 1 — Install / Upgrade | Install the application, or upgrade an existing installation while preserving its accounting data. |
| 2 — Status | Show the installed version, configured schedule, last successful check, and saved VPS balances. |
| 3 — Preview changes | Read current panel values and show proposed corrections. **No quota or accounting state is changed.** |
| 4 — Run one check | Perform a real accounting check now. **This can change quotas after a detected reset.** |
| 5 — Enable automatic checks | Enable the application's one-minute Cron. |
| 6 — Pause automatic checks | Pause this application's checks and wait for its current accounting worker to finish. |
| 7 — Logs | Show recent application operations and errors. |
| 8 — Doctor | Check required files, saved data, Cron, and read-only API access. It does not change quotas. |
| 9 — Backup | Archive the accounting data, application files, and job settings; print the archive path. |
| 10 — Commands | Show the command-line reference. |
| 11 — Uninstall | Remove the application and its Cron. Keep accounting data, backups, logs, and current panel quotas. |
| 0 — Exit | Leave the menu. An enabled Cron continues running. |

In a normal interactive terminal, each menu/action uses its own screen. Direct commands and redirected logs remain ordinary text output.

<a name="en-commands"></a>

### Command-line reference

`reset-carryover` is a compatibility command supporting the same management subcommands as `kvm-bw`.

| Command | Purpose |
|---|---|
| `kvm-bw` | Open the interactive menu. |
| `kvm-bw status` | Show saved status and VPS balances. |
| `kvm-bw status --json` | Show status as JSON for monitoring tools. |
| `kvm-bw commands` | Print the complete command list. |
| `kvm-bw preview` | Read-only preview of proposed quota corrections. |
| `kvm-bw run` | Run one real check immediately, including when the automatic schedule is paused. |
| `kvm-bw start` or `kvm-bw enable` | Enable automatic checks. |
| `kvm-bw stop` or `kvm-bw disable` | Pause automatic checks. |
| `kvm-bw logs` | Show recent log entries. |
| `kvm-bw logs --lines 50` | Show up to 50 recent lines. |
| `kvm-bw doctor` | Run read-only health checks. |
| `kvm-bw backup` | Create a backup archive and print its location. |
| `kvm-bw upgrade` | Download the newer installer from this repository and upgrade. |
| `kvm-bw uninstall` | Remove the application and its job, retaining accounting data. |
| `kvm-bw version` | Print the version. |
| `kvm-bw policy minimum-1gb` | Use the minimum-1GB policy for very small balances. |
| `kvm-bw policy hold` | Stop automatic correction for a VPS whose carry-over would be below 1GB. |
| `kvm-bw resync VPS_ID` | Accept that VPS's current panel quota and usage as a new baseline. Read the explanation below before using it. |

### Changing the baseline with `resync`

Example for VPS 101:

```bash
kvm-bw resync 101
```

This takes a backup, then accepts the current panel values for that VPS. It does not reset panel usage or write a new panel quota. **It replaces the saved baseline and clears that VPS's saved fractional adjustment.** It is not a command to restore missing traffic. Check the intended allowance in the panel before running it.

<a name="en-status"></a>

### Understanding status and errors

| Status item | Meaning |
|---|---|
| `LIMIT_GB` | The panel quota at the last saved observation or confirmed correction. |
| `USED_GB` | The usage reported by the panel at that observation. |
| `LEFT_GB` | The remaining allowance calculated from saved values, including a fractional adjustment. |
| `tracking` | No held issue is recorded; normal comparisons can continue. |
| `pending` | A quota change was recorded before sending it. A later check must reconcile whether it completed. |
| `HELD`, `review-required`, or another explanation in `STATUS` | Automatic correction for that VPS needs operator review. It does **not** mean that this tool suspended the VPS. |
| `ENABLED / every minute` | The application's schedule is configured as enabled. Use Doctor to check the system Cron service too. |
| `PAUSED / not configured` | The application's automatic job is paused or absent. |
| `installed: legacy` | An older tool installation exists; upgrade it. |

Status displays saved observations, not a new live API query. A held or deleted VPS record may therefore show older values. One held VPS does not necessarily prevent other eligible VPSs from being processed.

After the managed version has completed checks, the log includes `RUN_OK` or `RUN_FAILED`. A quota correction is logged as `QUOTA-REPLACED`. If no full successful check has been recorded for more than three minutes while the schedule is enabled, Status displays an attention message.

Start troubleshooting with:

```bash
kvm-bw status
kvm-bw logs --lines 50
kvm-bw doctor
```

Do not fix an error by deleting the accounting file. A conflicting quota edit, changed VM identity, failed API write, or a finite/unlimited transition can require reviewing the panel values before an intentional resync.

### Fractional balances and the 1GB minimum

The tool writes whole-GB quotas and keeps fractional adjustments separately.

- With **700.52 GB** available at a reset, it writes a quota of **700 GB** and saves **+0.52 GB** for a later carry-over calculation. That fraction may not yet be usable through the panel's current whole-GB quota.
- With **less than 1 GB** available, the default `minimum-1gb` policy writes **1 GB**. For an available balance of **0.40 GB**, it records **−0.60 GB** to subtract from a later calculation.
- An exhausted balance can consequently receive up to 1 GB of panel allowance under this policy, in addition to the panel's usual enforcement delay. This is **not a strict zero-credit cutoff**.
- The alternative `hold` policy does not write a quota below 1GB. It records a held issue instead. **It does not disconnect the VPS; the previous, potentially larger quota can remain active until you handle it.** Changing policy does not automatically clear an already-held record.

The script never writes a depleted quota as `0`, because Virtualizor uses `0` for unlimited bandwidth.

### Data, backups, and removal

| Location | Contents |
|---|---|
| `/opt/reset-carryover/` | Application, PHP bridge, manager, and tests. |
| `/var/lib/reset-carryover/state.json` | Accounting history, balances, fractional adjustments, and pending operations. |
| `/var/lib/reset-carryover/state.previous.json` | The preceding saved accounting snapshot. |
| `/var/lib/reset-carryover/last-run.json` | Managed check timing and result metadata. |
| `/var/lib/reset-carryover/backups/` | Backup archives. |
| `/var/log/reset-carryover.log` | Application log. |
| `/etc/cron.d/reset-carryover` | This application's Cron job. |

Automatic backups are taken before upgrades, uninstall, policy changes, and resync. `kvm-bw backup` also creates one on demand. These archives are not a backup of the Virtualizor database, customer VM disks, or the entire server. A backup stored only on the same server does not protect against losing that server.

`kvm-bw uninstall` removes the program and its job, but retains accounting data and logs. It does not restore old quotas: if a quota had been corrected to 700 GB, uninstall leaves it at 700 GB. A later installation reuses valid saved history instead of enrolling it from scratch.

<a name="en-faq"></a>

### Frequently asked questions

**Does it cover a newly created VPS automatically?**  
Yes, at a later successful check, if it is an eligible local KVM VPS with a finite, whole-GB quota. Its current usage and quota become the initial baseline. A new VPS with `Bandwidth=0` is not enrolled.

**Can I keep adding traffic manually?**  
Yes. Increase the Bandwidth quota in Virtualizor. For example, changing 4,000 to 5,300 adds 1,300 GB to the panel allowance. A reduction removes allowance. The tool incorporates the current quota in its comparisons. Avoid editing quota while a correction is pending: checking the quota and writing it are separate API requests, not one atomic panel transaction.

**Can I use the Reset Bandwidth button to give a customer more traffic?**  
No. The tool treats that reset as a carry-over event too. Add traffic by increasing the quota instead.

**Does the Service period bandwidth calculation setting need to be on?**  
Either setting can be used. This version does not use that setting or a fixed calendar day to detect a reset; it compares usage values. If changing the setting lowers reported usage, that decrease is treated as a reset too.

**Does the tool block traffic or change network speed?**  
It only changes Bandwidth. Set the desired quota enforcement, such as `Bandwidth suspend`, in Virtualizor. Pausing or removing this tool does not toggle that panel setting.

**Why was nothing corrected after installation?**  
Initial enrollment only saves a baseline. A later observed reset is needed before a carry-over correction occurs. `ENROLLED` is a normal registration message.

**Does it check automatically, and does it update itself automatically?**  
Checks are enabled every minute on a fresh installation. Application updates are separate: invoke `upgrade` yourself. Closing SSH or choosing Exit does not stop enabled checks.

**What if I change a managed quota to zero?**  
Zero means unlimited in the panel. A finite/unlimited transition for an already tracked VPS is held for review. After returning to a finite quota, verify the intended panel values before resyncing. Do not use zero to represent an exhausted traffic package.

**Why can LEFT_GB differ from LIMIT_GB minus USED_GB?**  
The saved calculation includes the fractional adjustment described above. The panel itself uses the written quota; a saved fraction is not necessarily immediately usable traffic.

**Why does a deleted VPS still appear in Status?**  
Saved history is retained. Each real check processes the current eligible VPS list from the panel, not every historical row. A row in Status is not proof that the VM still exists. A reused identifier with a changed VM identity is held for review.

**What if the host reboots, the application stops, or an API call fails?**  
History is stored on disk. Pending operations help avoid repeating a completed correction. Checks can resume when the service and job are available, but resets and consumption missed during downtime cannot always be reconstructed. Use Status, Logs, and Doctor for held or failed checks.

**Is Preview safe for checking what would happen?**  
Preview reads current panel values without writing quotas or accounting state. `Run one check` is different: it performs real processing and can edit quotas.

**Can I automatically restore an old backup?**  
There is no automatic restore command. Restoring an old baseline against newer panel quotas can repeat a deduction or accept an incorrect allowance. Pause checks and reconcile the saved data with actual panel values before any manual restoration. Resync is not a backup restore.

**Do I need to publish API credentials on GitHub?**  
No. The bridge uses the local Virtualizor configuration. Upload the repository files only, not the server's `universal.php`, runtime accounting files, backup archives, or customer logs.

**Do installation tests change real customer VPSs?**  
The included tests use isolated fixtures and temporary data. They do not perform panel API writes. Passing tests is not a guarantee of accurate accounting or successful API writes on every server; verify the actual operation in your environment.

**Do I upload install.sh or install-reset-carryover.sh when maintaining the repository?**  
Both. `install.sh` is the short entry point; the longer filename is retained for compatibility and is used by the installed updater. Replace both together when publishing a code update. A README-only change does not require reinstalling or upgrading the application.

---

<a name="persian"></a>

<div dir="rtl">

## فارسی

[برنامه چه کار می‌کند؟](#fa-how) · [نصب و ارتقا](#fa-install) · [گزینه‌های منو](#fa-menu) · [دستورات](#fa-commands) · [وضعیت و خطاها](#fa-status) · [سؤال‌های رایج](#fa-faq)

<a name="fa-how"></a>

### این برنامه برای چه کاری است؟

فرض کنید به مشتری یک بستهٔ **۵۰۰۰ گیگابایتی** فروخته‌اید. قرار است این حجم تا زمانی که تمام نشده، برای مشتری باقی بماند. مشتری تا امروز **۴۳۰۰ گیگ** مصرف کرده و **۷۰۰ گیگ** دیگر دارد.

اگر پنل مصرف را ریست کند و سقف همچنان ۵۰۰۰ بماند، مشتری دوباره امکان استفاده از ۵۰۰۰ گیگ را پیدا می‌کند. این برنامه بعد از تشخیص ریست، **سقف پنل را به همان ۷۰۰ گیگ باقی‌مانده تغییر می‌دهد**.

| وضعیت | مصرف ثبت‌شده در پنل | سقف پنل | حجم باقی‌ماندهٔ مشتری |
|---|---:|---:|---:|
| قبل از ریست | ۴۳۰۰ گیگ | ۵۰۰۰ گیگ | ۷۰۰ گیگ |
| بعد از ریست، قبل از اصلاح | صفر | ۵۰۰۰ گیگ | پنل دوباره ۵۰۰۰ گیگ اجازهٔ مصرف نشان می‌دهد |
| بعد از اصلاح برنامه | صفر | **۷۰۰ گیگ** | **۷۰۰ گیگ** |

اگر مشتری بعد از ریست و قبل از اجرای برنامه، **۲۰ گیگ** هم مصرف کرده باشد، نتیجه باید **۲۰ گیگ مصرف از سقف ۷۰۰ گیگ** باشد. یعنی **۶۸۰ گیگ** برایش باقی می‌ماند. مصرف جدید به مشتری برگردانده نمی‌شود.

این برنامه برای فروش حجم‌هایی مناسب است که باید تا زمان مصرف‌شدن اعتبار داشته باشند. اگر سیاست فروش شما این است که مشتری در هر ماه یک بستهٔ کامل و تازه دریافت کند، باید آن سیاست شارژ ماهانه را جداگانه در نظر بگیرید؛ این برنامه خودش خرید، فاکتور یا شارژ جدیدی ایجاد نمی‌کند.

### برنامه از کجا می‌فهمد ریست اتفاق افتاده؟

در هر بررسی، مصرفی را که پنل گزارش می‌کند با عدد ذخیره‌شدهٔ بررسی قبلی مقایسه می‌کند. **هر وقت مصرف کمتر شده باشد، آن را ریست در نظر می‌گیرد.** لازم نیست مصرف حتماً به صفر رسیده باشد.

سپس حجم استفاده‌نشدهٔ قبلی را حساب می‌کند و آن را جای سقف قبلی می‌گذارد. تغییر دستی سقف و ماندهٔ کسری ذخیره‌شده هم در محاسبه لحاظ می‌شوند.

برای مثال ساده‌ای که ماندهٔ کسری ندارد:

**سقف جدید = سقف قبلی − مصرف قبلی + حجمی که خودتان به سقف اضافه یا از آن کم کرده‌اید**

عدد جدید **جایگزین سقف قبلی** می‌شود؛ به سقف قبلی اضافه نمی‌شود. نتیجه نیز ذخیره می‌شود تا اجرای دوبارهٔ برنامه، همان اصلاح را دوباره از حساب مشتری کم نکند.

### شرط مهم استفاده

**هنگام استفاده از این برنامه، مصرف را دستی ریست نکنید.**

برنامه تشخیص نمی‌دهد ریست را شما انجام داده‌اید یا پنل. ریست از طریق API، ریست توسط برنامهٔ صورتحساب یا حتی اصلاح آمار پنل هم اگر عدد مصرف را پایین بیاورند، ممکن است ریست حساب شوند. برای دادن حجم جدید به مشتری، **سقف Bandwidth را افزایش بدهید**.

### برنامه چه چیزی را تغییر می‌دهد؟

تنها مقدار **Bandwidth**، یعنی سقف حجم ترافیک VPS، را در Virtualizor تغییر می‌دهد.

قطع ترافیک، تعلیق و محدودیت سرعت همچنان به تنظیمات خود Virtualizor بستگی دارند. برنامه دستور قطع شبکه، Suspend، Unsuspend، تغییر سرعت، خاموش‌کردن VM یا ریست مصرف اجرا نمی‌کند. گزینهٔ `Bandwidth suspend` را هم خودکار برای شما روشن نمی‌کند.

### دقت محاسبات چقدر است؟

مبنای برنامه **مصرف گزارش‌شدهٔ پنل** است. برنامه روی کارت شبکه، بسته‌های ترافیک را مستقل نمی‌شمارد. این چند محدودیت را در نظر بگیرید:

- اگر مصرف ریست شود، اما تا بررسی بعدی دوباره به عدد قبلی برسد یا بیشتر شود، آن ریست دیده نمی‌شود. مثلاً عدد قبلی ۱ گیگ بوده و در بررسی بعدی، پس از ریست، ۲ گیگ مصرف دیده می‌شود.
- محاسبهٔ مصرف در خود پنل ممکن است با تأخیر انجام شود. فاصلهٔ این محاسبه و بررسی یک‌دقیقه‌ای برنامه می‌تواند بخشی از مصرف انتهای دوره را جا بیندازد.
- مصرف‌هایی که قبل از ثبت اولیهٔ برنامه ریست شده‌اند، از روی شمارندهٔ فعلی قابل بازیابی نیستند.
- کاهش غیرعادی آمار، حتی اگر ریست واقعی نباشد، ممکن است اصلاح سهمیه را فعال کند؛ چون قاعدهٔ این نسخه «هر افت مصرف، یک ریست» است.

بنابراین برنامه به معنای تضمین حسابداری بدون هیچ فاصله یا بازیابی همهٔ مصرف‌های گذشته نیست.

<a name="fa-install"></a>

### پیش‌نیازها

- دسترسی `root` به سرور اصلی که Virtualizor و VPSهای KVM محلی روی آن قرار دارند.
- Python نسخهٔ ۳٫۹ یا جدیدتر و فعال‌بودن سرویس `crond`.
- وجود PHP و SDK نصب‌شدهٔ Virtualizor در مسیرهای استاندارد.
- Bash و `curl` برای اجرای دستور دانلود.

هدف فعلی برنامه، محیط AlmaLinux 9 و Virtualizor KVM است. این نسخه **فقط VPSهای KVM محلی روی همان Master** را مدیریت می‌کند؛ در اطلاعات پنل، این VPSها `serid=0` دارند. مدیریت نودهای Slave، مجازی‌سازهای دیگر یا نصب‌هایی با ساختار متفاوت، در این نسخه پوشش داده نشده است.

بستهٔ اضافی Python لازم نیست. کلید API هم لازم نیست در کد وارد کنید؛ برنامه تنظیمات محلی پنل را می‌خواند.

### نصب برای اولین بار

روی سرور اصلی، با کاربر `root` اجرا کنید:

<div dir="ltr">

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh)
```

</div>

در منو **گزینهٔ ۱، Install / Upgrade** را انتخاب کنید.

برنامه ابتدا فایل‌ها را بررسی و تست‌های جدا از پنل را اجرا می‌کند. سپس سقف و مصرف فعلی هر VPS قابل‌مدیریت را ذخیره می‌کند. این اعداد، نقطهٔ شروع حسابداری برنامه می‌شوند. **در ثبت اولیه، سهمیه کم نمی‌شود و مصرف ریست نمی‌شود.**

بعد از نصب اولیه، بررسی خودکار **روشن است و هر یک دقیقه اجرا می‌شود**. بستن منو یا قطع‌کردن اتصال SSH آن را متوقف نمی‌کند.

اگر نمی‌خواهید وارد منو شوید، نصب مستقیم به این صورت است:

<div dir="ltr">

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh) install
```

</div>

### ارتقای نسخهٔ موجود

اگر دستور مدیریتی روی سرور نصب است، اجرا کنید:

<div dir="ltr">

```bash
kvm-bw upgrade
```

</div>

اگر نسخهٔ قدیمی را دارید و هنوز دستور `kvm-bw` موجود نیست:

<div dir="ltr">

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh) upgrade
```

</div>

در ارتقا، قبل از تعویض فایل‌ها پشتیبان گرفته می‌شود و مصرف‌ها، مانده‌ها و سیاست فعلی حفظ می‌شوند. اگر بررسی خودکار روشن بوده، روشن می‌ماند؛ اگر آن را متوقف کرده باشید، متوقف می‌ماند. **برای ارتقا، فایل سابقهٔ مصرف را حذف نکنید و حسابداری را از اول نسازید.**

اگر بالای منو نوشته شده `installed: legacy`، منظور نسخهٔ قدیمی **همین اسکریپت** است، نه نسخهٔ Virtualizor. صرفاً بازکردن منوی جدید، برنامهٔ نصب‌شده را ارتقا نمی‌دهد؛ باید گزینهٔ ۱ را انتخاب یا دستور ارتقا را اجرا کنید.

<a name="fa-menu"></a>

### هر گزینهٔ منو چه کاری انجام می‌دهد؟

بعد از نصب، برای بازکردن منو بنویسید:

<div dir="ltr">

```bash
kvm-bw
```

</div>

| گزینه | کاربرد |
|---|---|
| **۱ — Install / Upgrade** | نصب اولیه یا ارتقای برنامهٔ موجود، با حفظ سابقهٔ حسابداری. |
| **۲ — Status** | نمایش نسخه، وضعیت زمان‌بندی، آخرین بررسی موفق و ماندهٔ ذخیره‌شدهٔ VPSها. |
| **۳ — Preview changes** | خواندن اعداد فعلی پنل و نمایش اصلاحاتی که پیشنهاد می‌شود؛ **چیزی را تغییر نمی‌دهد**. |
| **۴ — Run one check** | اجرای یک بررسی واقعی همین حالا؛ **در صورت تشخیص ریست، ممکن است سقف‌ها را تغییر دهد**. |
| **۵ — Enable automatic checks** | فعال‌کردن Cron یک‌دقیقه‌ای همین برنامه. |
| **۶ — Pause automatic checks** | توقف بررسی خودکار همین برنامه و صبر تا پایان اجرای درحال‌انجام آن. |
| **۷ — Logs** | نمایش عملیات و خطاهای اخیر برنامه. |
| **۸ — Doctor** | بررسی فایل‌ها، داده‌ها، Cron و اتصال خواندنی API؛ بدون تغییر سهمیه. |
| **۹ — Backup** | پشتیبان از سابقهٔ مصرف، فایل‌های برنامه و تنظیمات کار؛ مسیر فایل را هم نشان می‌دهد. |
| **۱۰ — Commands** | نمایش فهرست دستورات مستقیم SSH. |
| **۱۱ — Uninstall** | حذف برنامه و Cron خودش؛ داده‌ها، پشتیبان‌ها، لاگ‌ها و سهمیه‌های فعلی پنل حفظ می‌شوند. |
| **۰ — Exit** | خروج از منو؛ بررسی خودکارِ روشن همچنان ادامه دارد. |

در ترمینال تعاملی معمولی، منو و نتیجهٔ هر گزینه در صفحهٔ جدا نمایش داده می‌شوند. دستورات مستقیم و خروجی‌هایی که در فایل ذخیره می‌شوند، به‌صورت متن عادی چاپ می‌شوند.

<a name="fa-commands"></a>

### دستورات مستقیم SSH

دستور قدیمی `reset-carryover` هم همین گزینه‌های مدیریتی را پشتیبانی می‌کند.

| دستور | توضیح |
|---|---|
| `kvm-bw` | بازکردن منو. |
| `kvm-bw status` | دیدن وضعیت ذخیره‌شده و ماندهٔ VPSها. |
| `kvm-bw status --json` | گرفتن وضعیت به شکل JSON برای ابزارهای مانیتورینگ. |
| `kvm-bw commands` | نمایش تمام دستورات. |
| `kvm-bw preview` | دیدن پیشنهاد اصلاح سهمیه، بدون اجرای آن. |
| `kvm-bw run` | اجرای یک بررسی واقعی؛ حتی وقتی بررسی خودکار متوقف است. |
| `kvm-bw start` یا `kvm-bw enable` | فعال‌کردن بررسی خودکار. |
| `kvm-bw stop` یا `kvm-bw disable` | متوقف‌کردن بررسی خودکار. |
| `kvm-bw logs` | دیدن لاگ‌های اخیر. |
| `kvm-bw logs --lines 50` | دیدن حداکثر ۵۰ خط آخر لاگ. |
| `kvm-bw doctor` | بررسی سلامت برنامه و اتصال خواندنی پنل. |
| `kvm-bw backup` | ساخت پشتیبان و نمایش محل آن. |
| `kvm-bw upgrade` | دریافت و نصب نسخهٔ جدید از همین مخزن. |
| `kvm-bw uninstall` | حذف برنامه و زمان‌بندی خودش، با نگهداری داده‌ها. |
| `kvm-bw version` | نمایش نسخه. |
| `kvm-bw policy minimum-1gb` | انتخاب حداقل سقف یک گیگ برای مانده‌های خیلی کم. |
| `kvm-bw policy hold` | توقف اصلاح خودکار برای VPSی که ماندهٔ قابل‌انتقالش کمتر از یک گیگ است. |
| `kvm-bw resync VPS_ID` | پذیرفتن اعداد فعلی پنل به‌عنوان نقطهٔ شروع جدید همان VPS؛ توضیح پایین را بخوانید. |

### دستور resync دقیقاً چه می‌کند؟

مثلاً برای VPS شمارهٔ ۱۰۱:

<div dir="ltr">

```bash
kvm-bw resync 101
```

</div>

این دستور اول پشتیبان می‌گیرد؛ سپس سقف و مصرف فعلی همان VPS را از پنل می‌خواند و جای اطلاعات ذخیره‌شدهٔ قبلی می‌گذارد. خودش مصرف پنل را ریست نمی‌کند و سقف جدیدی در پنل نمی‌نویسد.

**با این کار، مبنای قبلی جایگزین و ماندهٔ کسری ذخیره‌شدهٔ آن VPS صفر می‌شود.** پس `resync` راهی برای برگرداندن حجم گم‌شده نیست. اول بررسی کنید سهمیه و مصرف فعلی پنل همان چیزی است که می‌خواهید از این به بعد ملاک باشد؛ سپس آن را اجرا کنید.

<a name="fa-status"></a>

### معنی ستون‌ها و پیام‌های وضعیت

| عبارت | معنی ساده |
|---|---|
| `LIMIT_GB` | سقفی که در آخرین بررسی یا اصلاح تأییدشده ذخیره شده است. |
| `USED_GB` | مصرفی که پنل در همان بررسی گزارش کرده است. |
| `LEFT_GB` | ماندهٔ محاسبه‌شده از اطلاعات ذخیره‌شده، همراه با ماندهٔ کسری. |
| `tracking` | برای این VPS موردِ متوقف‌شده‌ای ثبت نشده و بررسی عادی می‌تواند ادامه پیدا کند. |
| `pending` | یک تغییر سهمیه قبل از ارسال ثبت شده و باید مشخص شود اجرای آن کامل شده یا نه. |
| `HELD`، `review-required` یا یک توضیح در ستون `STATUS` | اصلاح خودکار این VPS به بررسی شما نیاز دارد؛ به معنی تعلیق VPS توسط این برنامه نیست. |
| `ENABLED / every minute` | زمان‌بندی برنامه به‌صورت فعال تنظیم شده است؛ برای بررسی سرویس Cron خود سیستم از Doctor استفاده کنید. |
| `PAUSED / not configured` | زمان‌بندی برنامه متوقف است یا وجود ندارد. |
| `installed: legacy` | نسخهٔ قدیمی اسکریپت روی سرور وجود دارد و باید ارتقا داده شود. |

صفحهٔ Status اعداد **ذخیره‌شده** را نشان می‌دهد؛ هر بار بازکردنش، اطلاعات زنده را از API نمی‌گیرد. برای VPS حذف‌شده یا VPSی که اصلاح خودکارش به بررسی شما نیاز دارد، ممکن است اعداد مربوط به بررسی قدیمی باشند. مشکل یک VPS هم لزوماً باعث توقف بررسی تمام VPSهای دیگر نمی‌شود.

بعد از اجرای بررسی‌ها در نسخهٔ مدیریتی، پیام `RUN_OK` یا `RUN_FAILED` در لاگ ثبت می‌شود. اصلاح سقف با پیام `QUOTA-REPLACED` مشخص می‌شود. اگر زمان‌بندی روشن باشد ولی بیش از سه دقیقه بررسی کاملاً موفق ثبت نشده باشد، Status پیام توجه نشان می‌دهد.

برای شروع بررسی یک مشکل:

<div dir="ltr">

```bash
kvm-bw status
kvm-bw logs --lines 50
kvm-bw doctor
```

</div>

فایل حسابداری را برای رفع خطا پاک نکنید. تغییر هم‌زمان سقف، تغییر هویت VM، خطای API یا تغییر وضعیت محدود/نامحدود می‌تواند نیاز به بررسی اعداد پنل و بعد، همگام‌سازی آگاهانه داشته باشد.

### اگر مانده اعشاری باشد یا به کمتر از یک گیگ برسد چه می‌شود؟

برنامه سقف را بر حسب **گیگِ صحیح** می‌نویسد و بخش اعشاری را جدا نگه می‌دارد:

- اگر هنگام ریست **۷۰۰٫۵۲ گیگ** باقی مانده باشد، سقف پنل **۷۰۰ گیگ** می‌شود و **۰٫۵۲ گیگ** برای محاسبهٔ انتقال بعدی ذخیره می‌شود. ممکن است این بخش اعشاری هنوز از طریق سقف فعلی پنل قابل‌استفاده نباشد.
- سیاست پیش‌فرض برای ماندهٔ **کمتر از یک گیگ**، حداقل سقف **یک گیگ** است. مثلاً برای **۰٫۴۰ گیگ** مانده، سقف یک گیگ نوشته و **منفی ۰٫۶۰ گیگ** برای کسر از محاسبهٔ بعدی ذخیره می‌شود.
- بنابراین وقتی اعتبار تمام شده، این سیاست می‌تواند تا یک گیگ دیگر در پنل اجازهٔ مصرف بدهد؛ تأخیر معمول اعمال محدودیت پنل هم جداست. این رفتار به معنی قطع دقیق در اعتبار صفر نیست.
- اگر سیاست `hold` را انتخاب کنید، برنامه در این حالت سقف جدید نمی‌نویسد و مورد را برای بررسی نگه می‌دارد. **این سیاست VPS را قطع نمی‌کند؛ ممکن است سقف بزرگ قبلی تا رسیدگی شما فعال بماند.** تغییر سیاست هم مواردی را که قبلاً متوقف شده‌اند، خودکار آزاد نمی‌کند.

برنامه برای اعتبار تمام‌شده، مقدار **صفر** را در Bandwidth نمی‌نویسد؛ چون صفر در پنل یعنی **نامحدود**.

### فایل‌ها، پشتیبان‌گیری و حذف برنامه

| مسیر روی سرور | کاربرد |
|---|---|
| `/opt/reset-carryover/` | فایل‌های برنامه، رابط PHP، بخش مدیریت و تست‌ها. |
| `/var/lib/reset-carryover/state.json` | سابقهٔ مصرف، مانده‌ها، اعداد کسری و عملیات در انتظار. |
| `/var/lib/reset-carryover/state.previous.json` | نسخهٔ ذخیره‌شدهٔ قبلی اطلاعات حسابداری. |
| `/var/lib/reset-carryover/last-run.json` | زمان و نتیجهٔ آخرین بررسی‌های نسخهٔ مدیریتی. |
| `/var/lib/reset-carryover/backups/` | فایل‌های پشتیبان. |
| `/var/log/reset-carryover.log` | گزارش عملیات و خطاها. |
| `/etc/cron.d/reset-carryover` | زمان‌بندی همین برنامه. |

قبل از ارتقا، حذف برنامه، تغییر سیاست و `resync` پشتیبان گرفته می‌شود. با `kvm-bw backup` هم هر زمان می‌توانید پشتیبان بسازید. این فایل‌ها پشتیبانِ تمام سرور، دیتابیس Virtualizor یا دیسک VPSهای مشتری نیستند. نگهداری پشتیبان فقط روی همان سرور هم در برابر ازدست‌رفتن کل سرور کافی نیست.

با `kvm-bw uninstall`، برنامه و Cron خودش حذف می‌شوند؛ داده‌های حسابداری و لاگ‌ها باقی می‌مانند. سهمیه‌های قبلی هم برگردانده نمی‌شوند: **اگر سقف به ۷۰۰ گیگ اصلاح شده باشد، بعد از حذف هم همان ۷۰۰ می‌ماند.** نصب دوباره، سابقهٔ معتبر باقی‌مانده را استفاده می‌کند و حسابداری را از اول شروع نمی‌کند.

<a name="fa-faq"></a>

### سؤال‌های رایج

#### اگر VPS جدید بسازم، خودش اضافه می‌شود؟

بله؛ در یکی از بررسی‌های موفق بعدی، به شرط اینکه KVM محلی روی همین سرور باشد و سقف محدود بر حسب گیگ صحیح داشته باشد. مصرف و سقف همان زمان، نقطهٔ شروع آن VPS می‌شوند. VPS جدید با `Bandwidth=0`، چون نامحدود است، ثبت نمی‌شود.

#### برای مشتری چطور حجم اضافه کنم یا حجمش را کم کنم؟

همان فیلد **Bandwidth** را در Virtualizor ویرایش کنید. مثلاً تغییر **۴۰۰۰ به ۵۳۰۰** یعنی **۱۳۰۰ گیگ افزایش سهمیهٔ پنل**. کاهش سقف هم سهمیه را کم می‌کند. برنامه سقف فعلی را در محاسباتش لحاظ می‌کند.

وقتی یک اصلاح در حالت `pending` است، بهتر است هم‌زمان سقف را ویرایش نکنید. برنامه قبل از نوشتن، سقف را دوباره بررسی می‌کند؛ اما بررسی و نوشتن دو درخواست جدا به API هستند و یک تراکنش واحد داخل پنل نیستند.

#### می‌توانم برای شارژ مشتری، دکمهٔ Reset Bandwidth را بزنم؟

خیر؛ طبق قاعدهٔ این نسخه، آن ریست هم انتقال مانده حساب می‌شود. برای شارژ مشتری، **سقف را بیشتر کنید**.

#### تیک Service period bandwidth calculation باید روشن باشد یا خاموش؟

هر دو حالت قابل‌استفاده‌اند. این نسخه برای تشخیص ریست، به تیک یا یک روز ثابت در ماه وابسته نیست؛ عدد مصرف را مقایسه می‌کند. اگر تغییر این تیک باعث پایین‌آمدن مصرف گزارش‌شده شود، آن کاهش هم ریست حساب می‌شود.

#### خود برنامه ترافیک را قطع می‌کند یا سرعت را کم می‌کند؟

برنامه فقط Bandwidth را تغییر می‌دهد. تنظیم اعمال محدودیت، مثل `Bandwidth suspend`، را در خود Virtualizor انجام دهید. توقف یا حذف این اسکریپت هم آن گزینهٔ پنل را روشن یا خاموش نمی‌کند.

#### چرا بعد از نصب، هیچ سهمیه‌ای اصلاح نشد؟

نصب اول فقط اعداد فعلی را ذخیره می‌کند. برای انتقال مانده، باید در بررسی‌های بعدی یک ریست قابل‌مشاهده اتفاق بیفتد. پیام `ENROLLED` یعنی VPS ثبت شده و طبیعی است.

#### بررسی اتوماتیک روشن است؟ خودش هم آپدیت می‌شود؟

در نصب اولیه، بررسی هر دقیقه روشن است. آپدیت برنامه کار جداگانه‌ای است و باید خودتان `upgrade` را اجرا کنید. خروج از منو یا بستن SSH، بررسی خودکارِ روشن را متوقف نمی‌کند.

#### اگر Bandwidth یک VPS تحت نظارت را صفر کنم چه می‌شود؟

در پنل، صفر یعنی نامحدود. تغییر یک VPS ثبت‌شده بین حالت محدود و نامحدود، برای بررسی نگه داشته می‌شود. اگر دوباره سقف محدود تعیین کردید، اول اعداد موردنظر را در پنل بررسی کنید و بعد آن VPS را همگام کنید. برای نشان‌دادن تمام‌شدن بسته، سقف را صفر نکنید.

#### چرا گاهی ماندهٔ برنامه با «سقف منهای مصرف» دقیقاً یکسان نیست؟

چون برنامه عدد کسری ذخیره‌شده را هم در حساب مانده لحاظ می‌کند. پنل طبق سقفی که در آن نوشته شده عمل می‌کند؛ بخش کسریِ ذخیره‌شده لزوماً همان لحظه قابل‌استفاده نیست.

#### چرا VPS حذف‌شده هنوز در Status دیده می‌شود؟

برنامه سابقه را نگه می‌دارد. در بررسی واقعی، فهرست VPSهای قابل‌مدیریتِ فعلی را از پنل می‌خواند؛ همهٔ ردیف‌های تاریخی را پردازش نمی‌کند. پس وجود یک ردیف در Status به‌تنهایی به معنی وجود فعلی آن VM نیست. اگر شناسه‌ای دوباره استفاده شود ولی هویت VM عوض شده باشد، مورد برای بررسی نگه داشته می‌شود.

#### اگر سرور ریبوت شود، برنامه مدتی خاموش باشد یا API خطا بدهد چه می‌شود؟

سابقه روی دیسک ذخیره می‌شود. ثبت عملیات در انتظار کمک می‌کند اصلاحی که قبلاً انجام شده، دوباره تکرار نشود. بعد از در دسترس‌شدن سرویس و زمان‌بندی، بررسی‌ها می‌توانند ادامه پیدا کنند؛ اما همهٔ مصرف‌ها یا ریست‌هایی که در فاصلهٔ توقف دیده نشده‌اند، قابل بازسازی نیستند. وضعیت، لاگ و Doctor را برای خطاها و موارد متوقف‌شده بررسی کنید.

#### گزینهٔ Preview با Run one check چه فرقی دارد؟

Preview فقط اعداد فعلی پنل و پیشنهاد اصلاح را نشان می‌دهد؛ سهمیه یا اطلاعات حسابداری را تغییر نمی‌دهد. **Run one check بررسی واقعی است و می‌تواند سهمیه را ویرایش کند.**

#### چطور یک پشتیبان قدیمی را برگردانم؟

دستور بازگردانی خودکار وجود ندارد. برگرداندن مبنای قدیمی در حالی که سهمیه‌های پنل جدیدتر هستند، ممکن است باعث کسر دوباره یا پذیرفتن ماندهٔ اشتباه شود. قبل از بازیابی دستی، بررسی خودکار را متوقف و دادهٔ ذخیره‌شده را با اعداد واقعی پنل تطبیق دهید. `resync` هم به معنی بازگردانی پشتیبان نیست.

#### لازم است کلید API را داخل GitHub بگذارم؟

خیر. برنامه از تنظیمات محلی Virtualizor استفاده می‌کند. در مخزن فقط فایل‌های پروژه را قرار دهید؛ فایل `universal.php` سرور، فایل‌های حسابداری، پشتیبان‌ها یا لاگ مشتری‌ها را آپلود نکنید.

#### تست‌های نصب روی VPS واقعی مشتری اجرا می‌شوند؟

تست‌های همراه برنامه با داده‌های نمونه و فایل‌های موقت اجرا می‌شوند و درخواست ویرایش واقعی به API پنل نمی‌فرستند. پاس‌شدن تست‌ها، تضمین صحت حسابداری یا موفقیت ویرایش API در تمام سرورها نیست؛ عملکرد واقعی را در محیط خودتان هم بررسی کنید.

#### برای انتشار نسخهٔ جدید در GitHub، کدام فایل نصب را عوض کنم؟

هر دو فایل **`install.sh`** و **`install-reset-carryover.sh`** را با هم جایگزین کنید. اولی ورودی کوتاه نصب است؛ دومی برای سازگاری باقی مانده و دستور ارتقای برنامهٔ نصب‌شده از آن استفاده می‌کند. اگر فقط متن راهنما تغییر کرده، جایگزین‌کردن `README.md` کافی است و نیازی به نصب دوباره یا ارتقای برنامه ندارید.

</div>
