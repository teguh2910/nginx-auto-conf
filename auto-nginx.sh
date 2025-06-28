#!/bin/bash

# Fungsi untuk menampilkan pesan kesalahan
error_message() {
    echo -e "\e[31mError: $1\e[0m" >&2
    exit 1
}

# Fungsi untuk menampilkan pesan sukses
success_message() {
    echo -e "\e[32mSuccess: $1\e[0m"
}

# Meminta nama domain
read -p "Masukkan nama domain Anda (misalnya: example.com): " DOMAIN_NAME
if [[ -z "$DOMAIN_NAME" ]]; then
    error_message "Nama domain tidak boleh kosong."
fi

# Meminta root directory
read -p "Masukkan root directory untuk website Anda (misalnya: /var/www/html/$DOMAIN_NAME): " WEB_ROOT
if [[ -z "$WEB_ROOT" ]]; then
    error_message "Root directory tidak boleh kosong."
fi

# Memilih jenis backend
echo "Pilih jenis backend yang akan digunakan:"
echo "1) File Statis (HTML, CSS, JS)"
echo "2) Proxy Pass (untuk Node.js, Python, dll.)"
echo "3) FastCGI Pass (untuk PHP-FPM)"
read -p "Masukkan pilihan Anda (1/2/3): " BACKEND_TYPE

case "$BACKEND_TYPE" in
    1)
        USE_STATIC="y"
        USE_PROXY_PASS="n"
        USE_FASTCGI="n"
        ;;
    2)
        USE_STATIC="n"
        USE_PROXY_PASS="y"
        USE_FASTCGI="n"
        read -p "Masukkan port aplikasi Anda (misalnya: 3000): " APP_PORT
        if [[ -z "$APP_PORT" || ! "$APP_PORT" =~ ^[0-9]+$ ]]; then
            error_message "Port aplikasi harus berupa angka dan tidak boleh kosong."
        fi
        ;;
    3)
        USE_STATIC="n"
        USE_PROXY_PASS="n"
        USE_FASTCGI="y"
        read -p "Masukkan jalur FastCGI Unix socket atau alamat IP:Port (misalnya: unix:/var/run/php/php8.1-fpm.sock atau 127.0.0.1:9000): " FASTCGI_PASS_TARGET
        if [[ -z "$FASTCGI_PASS_TARGET" ]]; then
            error_message "Target FastCGI tidak boleh kosong."
        fi
        ;;
    *)
        error_message "Pilihan tidak valid. Silakan pilih 1, 2, atau 3."
        ;;
esac

# Lokasi default untuk konfigurasi Nginx
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

# Membuat root directory jika belum ada
if [[ ! -d "$WEB_ROOT" ]]; then
    echo "Membuat direktori web root: $WEB_ROOT"
    mkdir -p "$WEB_ROOT" || error_message "Gagal membuat direktori web root."
    # Atur izin direktori agar Nginx bisa membacanya
    sudo chown -R www-data:www-data "$WEB_ROOT"
    sudo chmod -R 755 "$WEB_ROOT"
fi

# Membuat file konfigurasi Nginx
CONF_FILE="$NGINX_CONF_DIR/$DOMAIN_NAME.conf"

echo "Membuat file konfigurasi Nginx: $CONF_FILE"
cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    root $WEB_ROOT; # Root directory selalu ada untuk semua tipe

EOF

if [[ "$USE_PROXY_PASS" == "y" ]]; then
    cat <<EOF >> "$CONF_FILE"
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
elif [[ "$USE_FASTCGI" == "y" ]]; then
    cat <<EOF >> "$CONF_FILE"
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass $FASTCGI_PASS_TARGET;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Deny access to .htaccess files, if Apache's document root
    # concurs with nginx's one
    location ~ /\.ht {
        deny all;
    }
EOF
else # USE_STATIC == "y"
    cat <<EOF >> "$CONF_FILE"
    index index.html index.htm index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
fi

cat <<EOF >> "$CONF_FILE"
    # Tambahkan konfigurasi SSL/TLS di sini nanti jika diperlukan
    # listen 443 ssl http2;
    # listen [::]:443 ssl http2;
    # ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    # Contoh konfigurasi untuk log
    access_log /var/log/nginx/$DOMAIN_NAME-access.log;
    error_log /var/log/nginx/$DOMAIN_NAME-error.log;
}
EOF

# Membuat symlink ke sites-enabled
echo "Membuat symlink ke $NGINX_ENABLED_DIR"
ln -s "$CONF_FILE" "$NGINX_ENABLED_DIR/" || error_message "Gagal membuat symlink."

# Menguji konfigurasi Nginx
echo "Menguji konfigurasi Nginx..."
sudo nginx -t
if [[ $? -ne 0 ]]; then
    error_message "Konfigurasi Nginx memiliki kesalahan. Silakan periksa log di atas."
fi

# Memuat ulang Nginx
read -p "Konfigurasi Nginx berhasil dibuat. Apakah Anda ingin me-reload Nginx sekarang? (y/n): " RELOAD_NGINX
RELOAD_NGINX=${RELOAD_NGINX,,}

if [[ "$RELOAD_NGINX" == "y" ]]; then
    echo "Me-reload Nginx..."
    sudo systemctl reload nginx || error_message "Gagal me-reload Nginx. Periksa status layanan."
    success_message "Nginx berhasil di-reload. Website Anda seharusnya sudah aktif."
else
    success_message "Konfigurasi Nginx berhasil dibuat. Jangan lupa me-reload Nginx secara manual (sudo systemctl reload nginx) agar perubahan diterapkan."
fi

echo -e "\n---"
echo "Langkah selanjutnya yang mungkin perlu Anda lakukan:"
echo "1. Pastikan DNS Anda mengarah ke server ini."
echo "2. Jika menggunakan SSL (HTTPS), jalankan Certbot atau cara lain untuk mendapatkan sertifikat SSL dan perbarui file konfigurasi Nginx ini."
echo "   Contoh dengan Certbot (setelah Nginx di-reload): sudo certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME"
echo "3. Pastikan PHP-FPM berjalan jika Anda memilih FastCGI."
echo "4. Letakkan file website Anda di $WEB_ROOT."
