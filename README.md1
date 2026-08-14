# 🛡️ Fix DNS Leak Test Script (برای اوبونتو)

این اسکریپت `setdns.sh` برای رفع مشکل **DNS Leak** در اوبونتو 20.04 و بالاتر طراحی شده است.  
هدف آن استفاده‌ی کامل از **Cloudflare DNS over HTTPS (DoH)** از طریق سرویس `cloudflared` است تا هیچ درخواست DNS به بیرون نشت نکند.  

---

## 🎯 قابلیت‌های اسکریپت

✅ به‌روزرسانی کامل و ارتقای سیستم (`upgrade + dist-upgrade`)  
✅ نصب ابزارهای ضروری + `nano` و `tmux`  
✅ نصب و پیکربندی سرویس رسمی `cloudflared`  
✅ تنظیم `systemd-resolved` برای هدایت همه درخواست‌ها به 127.0.0.1  
✅ تصحیح خودکار `/etc/resolv.conf`  
✅ تست خودکار پس از نصب (اطمینان از فعال بودن cloudflared روی پورت 53)  
✅ جلوگیری کامل از نشتی DNS (DNS Leak)  
 
✅ به همراه نصب داکر بر اساس سایت اوشن دیجیتال 

---

## ⚠️ نکته مهم

- در این نسخه دیگر از `resolvconf` استفاده نمی‌شود (حتی در صورت نصب، حذف خواهد شد).  
- کل سیستم شما در طول اجرا به آخرین نسخه‌های پایدار ارتقا داده می‌شود.  
- پس از پایان نصب می‌توانید نتیجه را با **Extended Test** در [dnsleaktest.com](https://dnsleaktest.com) بررسی کنید.  

---

## ⚙️ پیش‌نیازها

- Ubuntu 20.04 یا بالاتر  
- دسترسی `sudo`  
- اتصال اینترنت  

---

## 🚀 دانلود و اجرای مستقیم از GitHub

### 🚀 اجرای مستقیم با curl:
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/BigPyth0n/Fix-DNS-Leak-With-DockerOnly/refs/heads/main/DNSFixedWithDocker.sh)"
```

---

## 🧪 تست نهایی (دستی)

اسکریپت به‌صورت خودکار تست اولیه انجام می‌دهد.  


## 📁 آدرس GitHub

- [مشاهده فایل در GitHub](https://github.com/BigPyth0n/Fix-DNS-Leak-With-GPT)  
- [لینک مستقیم اسکریپت (Raw)](https://raw.githubusercontent.com/BigPyth0n/Fix-DNS-Leak-With-GPT/main/setdns.sh)  
