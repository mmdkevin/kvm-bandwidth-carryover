# KVM Bandwidth Carryover

<p dir="rtl">مدیریت حجم باقی‌ماندهٔ مشتریان در <strong>Virtualizor KVM</strong>، بدون شارژ دوبارهٔ سهمیه پس از ریست مصرف.</p>

Keep customers' remaining traffic allowance after usage resets in **Virtualizor KVM**.

[فارسی](#persian) | [English](#english)

---

<a name="persian"></a>

<div dir="rtl">

## فارسی

### این اسکریپت چه مشکلی را حل می‌کند؟

اگر VPS را با حجم مشخص می‌فروشید، ریست دوره‌ای مصرف در Virtualizor می‌تواند دوباره کل سهمیه را در اختیار مشتری بگذارد. این اسکریپت بعد از تشخیص ریست، **سقف ترافیک را به حجم باقی‌ماندهٔ مشتری تغییر می‌دهد**.

مثلاً مشتری از **۵۰۰۰ گیگ، ۴۳۰۰ گیگ** مصرف کرده است:

| وضعیت | مصرف در پنل | سقف ترافیک | باقی‌مانده |
|---|---:|---:|---:|
| قبل از ریست | ۴۳۰۰ گیگ | ۵۰۰۰ گیگ | ۷۰۰ گیگ |
| بعد از ریست و اصلاح اسکریپت | صفر | **۷۰۰ گیگ** | **۷۰۰ گیگ** |

این روش برای فروش حجمی مناسب است که اعتبار آن باید تا زمان مصرف‌شدن باقی بماند.

### نصب

با کاربر `root` روی **سرور اصلی Virtualizor** اجرا کنید و گزینهٔ **۱ — Install / Upgrade** را بزنید:

<div dir="ltr">

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh)
```

</div>

در شروع، حجم و مصرف فعلی ثبت می‌شود؛ بررسی خودکار **هر دقیقه** ادامه پیدا می‌کند، حتی بعد از بستن SSH. برای بازکردن منوی مدیریت بنویسید **`kvm-bw`**؛ مشاهدهٔ وضعیت، گزارش‌ها، توقف بررسی‌ها و حذف برنامه از همان منو انجام می‌شود.

محیط‌های هدف: **AlmaLinux 9 و Ubuntu 22.04 / 24.04**، برای VPSهای KVM روی همان سرور اصلی؛ نودهای Slave پوشش داده نمی‌شوند. اجرای کامل روی میزبان واقعی Ubuntu هنوز آزمایش نشده است.

### قبل از استفاده بدانید

- **برای شارژ مشتری، فیلد Bandwidth را افزایش دهید؛ مصرف را دستی ریست نکنید.** اسکریپت هر کاهش مصرف را ریست حساب می‌کند.
- VPSهای جدید با سهمیهٔ محدود، خودکار به بررسی‌ها اضافه می‌شوند.
- اسکریپت فقط سقف ترافیک را تغییر می‌دهد؛ قطع یا تعلیق VPS به تنظیمات خود Virtualizor بستگی دارد. حداقل سقف پیش‌فرض یک گیگ است، پس قطع دقیق در اعتبار صفر ندارد.
- دقت محاسبه به آمار پنل و فاصلهٔ بررسی‌ها وابسته است؛ بعضی ریست‌ها یا مصرف‌ها ممکن است دیده نشوند. مصرف ریست‌شدهٔ قبل از نصب بازیابی نمی‌شود.

<details>
<summary>ارتقا، حذف و نگهداری اطلاعات</summary>

- **ارتقا:** سابقهٔ فعال و تنظیم روشن یا خاموش بودن بررسی‌ها حفظ می‌شود.
- **حذف:** برنامه، کرون، سابقه، لاگ و پشتیبان‌های خودش کامل پاک می‌شوند؛ سهمیه و مصرف داخل پنل تغییر نمی‌کند.
- **نصب دوباره پس از حذف:** اعداد فعلی پنل مبنا می‌شوند؛ سابقهٔ نصب قبلی ملاک نیست.
- **نگهداری فایل‌ها:** لاگ‌ها تا ۲۰ مگابایت و حداکثر ۷ روز؛ پشتیبان‌ها حداکثر ۵ فایل تا ۷ روز. سابقهٔ VPS حذف‌شده پس از ۷ روز از تشخیص غیبتش، در بررسی بعدی پاک می‌شود. پاک‌سازی همراه بررسی‌های برنامه انجام می‌شود.

</details>

</div>

---

<a name="english"></a>

## English

### What problem does it solve?

When you sell a VPS with a fixed traffic allowance, a periodic Virtualizor usage reset can give the customer the full allowance again. This tool detects the reset and **replaces the quota with the customer's remaining traffic allowance**.

For example, a customer has used **4,300 GB of 5,000 GB**:

| Stage | Panel usage | Traffic quota | Remaining |
|---|---:|---:|---:|
| Before the reset | 4,300 GB | 5,000 GB | 700 GB |
| After the reset and correction | 0 GB | **700 GB** | **700 GB** |

Use this approach for traffic packages that should remain available until consumed.

### Installation

Run as `root` on the **main Virtualizor host**, then choose **1 — Install / Upgrade**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install.sh)
```

The tool starts by recording current usage and quotas, then checks **every minute**, even after SSH closes. Run **`kvm-bw`** to open the menu for status, logs, pausing checks, and removal.

Target systems: **AlmaLinux 9 and Ubuntu 22.04 / 24.04**, managing KVM guests on the same main host. Slave nodes are not covered. A full installation on a real Ubuntu Virtualizor host has not yet been tested.

### Before you use it

- **Add traffic by increasing Bandwidth; do not manually reset usage.** Every observed decrease in usage counts as a reset.
- New VPSs with finite quotas are automatically included in future checks.
- The tool only changes traffic quotas. Suspension and traffic enforcement depend on Virtualizor settings. The default minimum quota is 1 GB, so this is not a strict zero-credit cutoff.
- Accuracy depends on panel statistics and the check interval; some resets or consumption may be missed. Usage reset before installation cannot be recovered.

<details>
<summary>Upgrades, removal, and data retention</summary>

- **Upgrade:** preserve active accounting data and the enabled/paused schedule.
- **Uninstall:** remove the application, its Cron, accounting data, logs, and backups. Panel usage and quotas stay unchanged.
- **Reinstall after removal:** start from current panel values, ignoring old accounting data.
- **File retention:** logs up to 20 MiB and 7 days; up to 5 backups for 7 days. Deleted VPS records are removed on the first check at least 7 days after their absence is detected. Cleanup runs alongside the application's checks.

</details>
