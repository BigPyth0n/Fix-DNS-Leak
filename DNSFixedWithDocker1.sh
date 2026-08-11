#!/bin/bash
set -euo pipefail

# رنگ‌ها برای خروجی زیباتر
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# توابع کمکی
error_exit() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# بررسی دسترسی root
if [ "$EUID" -ne 0 ]; then
    error_exit "لطفاً اسکریپت را با دسترسی root اجرا کنید (sudo)."
fi

info "اسکریپت رفع نشت DNS با استفاده از Docker و Cloudflared شروع شد."

# ========== نصب ابزارهای ضروری ==========
if ! command -v dig &> /dev/null; then
    info "نصب dnsutils (برای دستور dig)..."
    apt update -y
    apt install -y dnsutils
fi

if ! command -v ss &> /dev/null; then
    info "نصب iproute2 (برای دستور ss)..."
    apt install -y iproute2
fi

# ========== نصب Docker ==========
if ! command -v docker &> /dev/null; then
    info "Docker یافت نشد. نصب Docker..."
    apt update -y
    apt install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    info "Docker نصب شد."
else
    info "Docker قبلاً نصب شده است."
fi

# اطمینان از فعال بودن Docker
systemctl enable docker
systemctl start docker

# ========== راه‌اندازی cloudflared به عنوان DNS proxy ==========
# اگر کانتینر قبلاً وجود دارد، حذف و دوباره ایجاد می‌کنیم
if docker ps -a --format '{{.Names}}' | grep -q "^cloudflared$"; then
    warn "کانتینر cloudflared قبلاً وجود دارد. حذف و ایجاد مجدد..."
    docker stop cloudflared >/dev/null 2>&1 || true
    docker rm cloudflared >/dev/null 2>&1 || true
fi

info "راه‌اندازی کانتینر cloudflared به عنوان DNS proxy روی 127.0.0.1:53..."
docker run -d \
    --name cloudflared \
    --restart unless-stopped \
    -p 127.0.0.1:53:53/udp \
    cloudflare/cloudflared:latest proxy-dns

# صبر کوتاه برای راه‌اندازی
sleep 2

# بررسی اینکه cloudflared روی پورت 53 شنود دارد
if ss -tulnp | grep -q "127.0.0.1:53"; then
    info "cloudflared با موفقیت روی 127.0.0.1:53 راه‌اندازی شد."
else
    warn "cloudflared روی 127.0.0.1:53 شنود ندارد. ممکن است خطایی رخ داده باشد."
fi

# ========== تست DNS ==========
info "اجرای تست‌های DNS..."

# تست ۱: dig مستقیم به 127.0.0.1
echo -e "\n--- تست ۱: پرس‌وجوی مستقیم به DNS محلی (127.0.0.1) ---"
if dig +time=2 +tries=1 +short @127.0.0.1 google.com >/dev/null 2>&1; then
    echo -e "${GREEN}✓ DNS محلی پاسخگو است.${NC}"
    dig +time=2 +tries=1 +short @127.0.0.1 google.com
else
    echo -e "${RED}✗ DNS محلی پاسخگو نیست.${NC}"
fi

# تست ۲: پرس‌وجوی whoami.cloudflare از طریق DNS محلی
echo -e "\n--- تست ۲: دریافت IP از طریق whoami.cloudflare (DNS محلی) ---"
LOCAL_IP=$(dig +short TXT whoami.cloudflare @127.0.0.1 2>/dev/null | tr -d '"')
if [ -n "$LOCAL_IP" ]; then
    echo -e "${GREEN}✓ IP شناسایی شده توسط DNS محلی: $LOCAL_IP${NC}"
else
    echo -e "${RED}✗ دریافت IP از DNS محلی ممکن نیست.${NC}"
fi

# تست ۳: پرس‌وجوی whoami.cloudflare از طریق 1.1.1.1
echo -e "\n--- تست ۳: دریافت IP از طریق 1.1.1.1 (Cloudflare) ---"
CF_IP=$(dig +short TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"')
if [ -n "$CF_IP" ]; then
    echo -e "${GREEN}✓ IP شناسایی شده توسط 1.1.1.1: $CF_IP${NC}"
else
    echo -e "${RED}✗ دریافت IP از 1.1.1.1 ممکن نیست.${NC}"
fi

# تست ۴: مقایسه IP‌ها (در صورت وجود)
if [ -n "$LOCAL_IP" ] && [ -n "$CF_IP" ]; then
    if [ "$LOCAL_IP" = "$CF_IP" ]; then
        echo -e "\n${GREEN}✓ نتیجه: DNS محلی و 1.1.1.1 IP یکسانی را گزارش کردند. نشتی DNS وجود ندارد.${NC}"
    else
        echo -e "\n${RED}✗ نتیجه: DNS محلی IP متفاوتی گزارش کرد. ممکن است نشتی وجود داشته باشد.${NC}"
    fi
fi

# تست ۵: بررسی تنظیمات سیستم (resolvectl یا /etc/resolv.conf)
echo -e "\n--- تست ۴: بررسی تنظیمات DNS سیستم ---"
if command -v resolvectl &> /dev/null; then
    echo "resolvectl status:"
    resolvectl status 2>/dev/null | grep -E "DNS Servers|Current DNS Server" || echo "  (اطلاعاتی یافت نشد)"
else
    echo "/etc/resolv.conf:"
    grep nameserver /etc/resolv.conf 2>/dev/null || echo "  (فایل موجود نیست)"
fi

# تست ۶: تست نشت با dnsleaktest
echo -e "\n--- تست ۵: انجام ۳ پرس‌وجوی آزمایشی برای تشخیص نشت ---"
for i in {1..3}; do
    result=$(dig +short @127.0.0.1 test$i.dnsleaktest.com 2>/dev/null || echo "FAILED")
    if [[ "$result" == "FAILED" ]]; then
        echo -e "test$i: ${RED}خطا در پرس‌وجو${NC}"
    else
        echo "test$i: $result"
    fi
done

# ========== جمع‌بندی نهایی ==========
echo -e "\n=============================================="
if ss -tulnp | grep -q "127.0.0.1:53" && dig +short @127.0.0.1 google.com >/dev/null 2>&1; then
    echo -e "${GREEN}✅ وضعیت نهایی: DNS proxy (cloudflared) به درستی کار می‌کند.${NC}"
    echo -e "${GREEN}✅ نشتی DNS برطرف شده است. تمام درخواست‌های DNS از طریق localhost (127.0.0.1) انجام می‌شود.${NC}"
else
    echo -e "${RED}❌ وضعیت نهایی: DNS proxy با مشکل مواجه است. لطفاً خطاهای بالا را بررسی کنید.${NC}"
fi
echo "=============================================="
echo -e "\n${YELLOW}توصیه: برای استفاده کامل، ممکن است نیاز باشد DNS سیستم خود را روی 127.0.0.1 تنظیم کنید.${NC}"
echo -e "${YELLOW}مثال: sudo resolvectl dns eth0 127.0.0.1 (برای اینترفیس eth0)${NC}"
echo -e "${YELLOW}یا: sudo systemctl restart systemd-resolved (پس از تغییر)${NC}"
