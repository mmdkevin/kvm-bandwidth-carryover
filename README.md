# KVM Bandwidth Carryover

<p dir="rtl">این اسکریپت به شکل اتوماتیک در <strong>Virtualizor KVM</strong> زمانی که ریست دوره ای انجام میشود سقف ترافیک را به حجم باقی مانده هر VPS تبدیل می کند.</p>

This script automatically sets each VPS's traffic quota to its remaining allowance when a periodic usage reset occurs in **Virtualizor KVM**.

[فارسی](#persian) | [English](#english)

---

<a name="persian"></a>

<div dir="rtl">

## فارسی

### این اسکریپت چه مشکلی را حل می‌کند؟

اگر VPS را با حجم مشخصی تعریف کرده اید، ریست دوره‌ای مصرف در Virtualizor می‌تواند دوباره کل ترافیک را در اختیار مشتری بگذارد. این اسکریپت بعد از تشخیص ریست، **سقف ترافیک را به حجم باقی مانده هر VPS تغییر می‌دهد**.

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

در ابتدا، حجم و مصرف فعلی VPS ها ثبت می‌شود؛ بررسی خودکار **هر 1 دقیقه** است، حتی بعد از بستن SSH. برای بازکردن منوی مدیریت بنویسید `kvm-bw`؛ مشاهدهٔ وضعیت، گزارش‌ها، توقف بررسی‌ها و حذف کامل اسکریپت از همان منو انجام می‌شود.

محیط‌های هدف: **AlmaLinux 9 و Ubuntu 22.04 / 24.04**

### قبل از استفاده بدانید

- **برای تغییرات ترافیک فیلد Bandwidth را افزایش یا کاهش دهید؛ مصرف را دستی ریست نکنید.** اسکریپت هر کاهش مصرف را ریست دوره ای حساب می‌کند.
- اگر VPS جدید با ترافیک محدود ساخته شود، خودکار به لیست بررسی‌ها اضافه می شود.
- اسکریپت فقط سقف ترافیک را تغییر می‌دهد؛ قطع یا تعلیق VPS به تنظیمات خود Virtualizor بستگی دارد.
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

When you configure a VPS with a fixed traffic allowance, a periodic Virtualizor usage reset can give the customer the full allowance again. This script detects the reset and **sets each VPS's traffic quota to its remaining allowance**.

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

The script first records current VPS usage and quotas, then checks automatically **every 1 minute**, even after SSH closes. Run `kvm-bw` to open the menu for status, logs, pausing checks, and complete script removal.

Target systems: **AlmaLinux 9 and Ubuntu 22.04 / 24.04**

### Before you use it

- **Adjust traffic by increasing or decreasing Bandwidth; do not manually reset usage.** The script treats every observed decrease in usage as a periodic reset.
- If a new VPS is created with a finite traffic allowance, it is automatically included in checks.
- The script only changes traffic quotas. VPS disconnection or suspension depends on Virtualizor settings.
- Accuracy depends on panel statistics and the check interval; some resets or consumption may be missed. Usage reset before installation cannot be recovered.

<details>
<summary>Upgrades, removal, and data retention</summary>

- **Upgrade:** preserve active accounting data and the enabled/paused schedule.
- **Uninstall:** remove the application, its Cron, accounting data, logs, and backups. Panel usage and quotas stay unchanged.
- **Reinstall after removal:** start from current panel values, ignoring old accounting data.
- **File retention:** logs up to 20 MiB and 7 days; up to 5 backups for 7 days. Deleted VPS records are removed on the first check at least 7 days after their absence is detected. Cleanup runs alongside the application's checks.

</details>
