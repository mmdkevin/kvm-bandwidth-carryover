# KVM Bandwidth Carryover

انتقال ماندهٔ ترافیک VPSهای KVM محلی در Virtualizor روی AlmaLinux.
هر افت مشاهده‌شدهٔ مصرف، ریست محسوب می‌شود. فقط سقف Bandwidth اصلاح می‌شود؛
اسکریپت دستور قطع شبکه یا تعلیق ندارد. Cron هر دقیقه اجرا می‌شود.

## نصب از GitHub

این فایل‌ها باید در ریشهٔ مخزن `mmdkevin/kvm-bandwidth-carryover` روی شاخهٔ `main` باشند.
دستور را روی سرور اصلی، با کاربر root اجرا کنید:

```bash
curl -fL --retry 3 "https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install-reset-carryover.sh" -o /root/install-reset-carryover.sh && bash /root/install-reset-carryover.sh
```

## وضعیت

```bash
reset-carryover status
tail -n 30 /var/log/reset-carryover.log
reset-carryover backup
```

ریست دستی مصرف نزنید؛ برنامه آن را هم ریست دوره‌ای حساب می‌کند.
برای ماندهٔ زیر ۱ گیگ، سقف پیش‌فرض حداقل ۱ گیگ است؛ صفر در پنل نامحدود است.
اگر مصرف پس از ریست، پیش از نمونهٔ بعدی به عدد قبلی برسد یا بیشتر شود، آن ریست دیده نمی‌شود.
مبنا آخرین مصرف گزارش‌شدهٔ پنل است؛ تاخیر پنل و فاصلهٔ نمونه‌ها می‌تواند مصرف انتهای دوره را جا بیندازد.
نصب‌کننده ۲۵ تست مستقل و بررسی نحوی PHP را قبل از فعال‌سازی Cron اجرا می‌کند.
ویرایش واقعی API و ریست واقعی روی سرور مقصد باید بررسی شوند.
فایل `/var/lib/reset-carryover/state.json` را حذف نکنید و برای بروزرسانی، مبنا را از نو نسازید.
