# KVM Bandwidth Carryover

<p dir="rtl">اسکریپتی برای مدیریت ماندهٔ ترافیک <strong>VPSهای KVM در پنل Virtualizor</strong>. بعد از ریست‌شدن مصرف، سقف ترافیک را به حجم باقی‌ماندهٔ مشتری تغییر می‌دهد تا سهمیهٔ کامل قبلی دوباره شارژ نشود.</p>

A bandwidth carry-over tool for **KVM VPSs managed by Virtualizor**. After a usage reset, it replaces the traffic quota with the customer's remaining allowance instead of granting the full quota again.

[فارسی](#persian) | [English](#english)

---

<a name="persian"></a>

<div dir="rtl">

## فارسی

### چطور کار می‌کند؟

مثلاً مشتری از **۵۰۰۰ گیگ، ۴۳۰۰ گیگ** مصرف کرده و **۷۰۰ گیگ** دارد. وقتی پنل مصرف را ریست کند، برنامه سقف را از ۵۰۰۰ به **۷۰۰ گیگ** تغییر می‌دهد. اگر بعد از ریست ۲۰ گیگ مصرف شده باشد، نتیجه **۲۰ از ۷۰۰ گیگ** است؛ یعنی ۶۸۰ گیگ باقی می‌ماند.

برنامه هر دقیقه مصرف پنل را با آخرین عدد ذخیره‌شده مقایسه می‌کند. **هر کاهش مصرف را ریست حساب می‌کند**؛ علت و تاریخ ریست را تشخیص نمی‌دهد. فقط سقف `Bandwidth` را تغییر می‌دهد؛ قطع یا تعلیق VPS به تنظیمات خود Virtualizor بستگی دارد.

### نصب و مدیریت

این نسخه برای **KVMهای محلی روی سرور Master با `serid=0`** نوشته شده؛ نودهای Slave را پوشش نمی‌دهد. محیط‌های هدف **AlmaLinux 9 و Ubuntu 22.04 / 24.04** هستند. Python 3.9+، PHP و SDK محلی Virtualizor و سرویس فعال Cron لازم‌اند.

برنامه سرویس `cron` یا `crond` را خودکار تشخیص می‌دهد. اگر وابستگی‌ای کم باشد، دستور مناسب `apt-get` یا `dnf` را نشان می‌دهد؛ خودش بسته نصب نمی‌کند یا سرویس سیستم را روشن نمی‌کند. سازگاری با تست‌های شبیه‌سازی‌شده بررسی شده؛ اجرای کامل روی میزبان واقعی Ubuntu هنوز آزمایش نشده است.

با کاربر `root` روی سرور اصلی اجرا کنید و گزینهٔ **۱ — Install / Upgrade** را بزنید:

<div dir="ltr">

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh)
```

</div>

نصب اول فقط مصرف و سقف فعلی را ثبت می‌کند؛ سهمیه را تغییر نمی‌دهد. بررسی خودکار از همان نصب **هر دقیقه روشن است** و با بستن SSH متوقف نمی‌شود. ارتقا، سابقه و وضعیت روشن یا خاموش زمان‌بندی را حفظ می‌کند.

| دستور | کاربرد |
|---|---|
| `kvm-bw` | منوی نصب، مدیریت، لاگ، پشتیبان و حذف |
| `kvm-bw status` | وضعیت بررسی خودکار و آخرین مانده‌های ذخیره‌شده |
| `kvm-bw preview` | نمایش اصلاحات پیشنهادی، بدون تغییر اطلاعات |
| `kvm-bw run` | یک بررسی واقعی؛ ممکن است سقف را تغییر دهد |
| `kvm-bw start` / `kvm-bw stop` | روشن یا متوقف‌کردن بررسی خودکار |
| `kvm-bw logs` / `kvm-bw doctor` | گزارش عملیات و بررسی سلامت برنامه |
| `kvm-bw backup` / `kvm-bw upgrade` | پشتیبان‌گیری یا ارتقای برنامه |
| `kvm-bw uninstall` | حذف برنامه؛ داده‌های حسابداری و سقف‌های فعلی حفظ می‌شوند |
| `kvm-bw commands` | فهرست کامل دستورات |

### سؤال‌های مهم

- **برای مشتری حجم اضافه یا کم کنم؟** همان فیلد Bandwidth را ویرایش کنید؛ تغییر ۴۰۰۰ به ۵۳۰۰ یعنی ۱۳۰۰ گیگ افزایش. هنگام اصلاح در حالت `pending`، هم‌زمان سقف را تغییر ندهید.
- **ریست دستی بزنم؟** خیر؛ آن هم ریست دوره‌ای حساب می‌شود. برای شارژ مشتری، سقف را افزایش دهید.
- **VPS جدید اضافه می‌شود؟** بله؛ KVM محلی با سقف محدود و عدد صحیح، در بررسی موفق بعدی خودکار ثبت می‌شود. سقف صفر یعنی نامحدود و برای VPS جدید ثبت نمی‌شود.
- **تیک Service period bandwidth calculation مهم است؟** هر دو حالت قابل‌استفاده‌اند؛ تشخیص با کاهش مصرف است. تغییر این تنظیم هم اگر مصرف را پایین بیاورد، ریست حساب می‌شود.
- **وقتی حجم تمام شد چه می‌شود؟** برنامه خودش VPS را قطع نمی‌کند و `Bandwidth suspend` را روشن نمی‌کند. برای ماندهٔ زیر یک گیگ، پیش‌فرض سقف **یک گیگ** است و اختلاف برای محاسبهٔ بعد ذخیره می‌شود؛ پس قطع دقیق در اعتبار صفر ندارد. سقف صفر نمی‌نویسد، چون در پنل یعنی نامحدود.

### محدودیت‌های ضروری

برنامه از آمار پنل استفاده می‌کند، نه شمارش مستقل ترافیک. تأخیر آمار یا ریستی که تا بررسی بعد مصرفش به عدد قبلی رسیده، ممکن است باعث جاافتادن مصرف یا ریست شود. ریست‌های قبل از نصب هم قابل بازیابی نیستند.

**فایل `/var/lib/reset-carryover/state.json` را حذف نکنید**؛ سابقهٔ حسابداری در آن است. در صورت خطا، از `status`، `logs` و `doctor` شروع کنید. دستور `resync` اعداد فعلی پنل را مبنای جدید می‌کند و ماندهٔ کسری ذخیره‌شده را پاک می‌کند؛ ابزار برگرداندن حجم نیست.

</div>

---

<a name="english"></a>

## English

### How it works

A VPS has used **4,300 GB of 5,000 GB**, leaving **700 GB**. After Virtualizor resets usage, the tool replaces the quota with **700 GB**. If 20 GB has already been used since the reset, the result is **20 GB of 700 GB**, leaving 680 GB.

It checks reported usage every minute. **Every observed decrease counts as a reset**, regardless of cause or date. It only edits the `Bandwidth` quota. VPS suspension and traffic enforcement remain Virtualizor settings.

### Installation and management

This release supports **local KVM guests on the Master host (`serid=0`)**, not Slave nodes. Target systems are **AlmaLinux 9 and Ubuntu 22.04 / 24.04**, requiring Python 3.9+, the local Virtualizor PHP/SDK installation, and an active Cron service.

The tool detects `cron` or `crond` and provides `apt-get` or `dnf` dependency instructions when needed. It does not install packages or start system services automatically. Compatibility has been checked with simulated tests; a full installation on a real Ubuntu Virtualizor host has not yet been tested.

Run as `root` on the main host, then choose **1 — Install / Upgrade**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh)
```

Initial enrollment saves current usage and quota without editing quotas. Fresh installation **enables checks every minute**; closing SSH does not stop them. Upgrades preserve accounting history and the enabled/paused schedule.

| Command | Purpose |
|---|---|
| `kvm-bw` | Menu for installation, management, logs, backups, and removal |
| `kvm-bw status` | Schedule status and last saved balances |
| `kvm-bw preview` | Read-only preview of proposed corrections |
| `kvm-bw run` | One real check; may edit quotas |
| `kvm-bw start` / `kvm-bw stop` | Enable or pause automatic checks |
| `kvm-bw logs` / `kvm-bw doctor` | Operation log and health checks |
| `kvm-bw backup` / `kvm-bw upgrade` | Create a backup or upgrade |
| `kvm-bw uninstall` | Remove the application; retain accounting data and current panel quotas |
| `kvm-bw commands` | Complete command reference |

### Common questions

- **Can I add or remove traffic?** Edit Bandwidth normally. Changing 4,000 to 5,300 adds 1,300 GB. Avoid concurrent edits while a correction is `pending`.
- **Can I reset usage manually?** No. Manual resets also trigger carry-over. Increase the quota to grant more traffic.
- **Are new VPSs enrolled?** Yes, at a later successful check, for local KVM guests with a finite whole-GB quota. New guests with a zero/unlimited quota are skipped.
- **Does Service period bandwidth calculation need to be enabled?** Either setting works. Detection uses a usage decrease; changing the setting can also trigger correction if usage drops.
- **What happens when credit runs out?** The tool does not suspend VPSs or enable `Bandwidth suspend`. Below 1 GB, the default policy writes a **1 GB** quota and records the difference for later calculations. It is not a strict zero-credit cutoff. It never writes zero as depleted credit, because zero means unlimited in the panel.

### Essential limitations

The tool relies on panel statistics, not independent traffic metering. Reporting delays can miss consumption. A reset is missed if usage reaches the previous reading before the next observation. Resets before enrollment cannot be recovered.

**Keep `/var/lib/reset-carryover/state.json`**: it holds the accounting history. Start troubleshooting with `status`, `logs`, and `doctor`. `resync` accepts current panel values as a new baseline and clears the saved fractional adjustment; it does not restore missing traffic.
