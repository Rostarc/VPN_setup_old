#!/bin/bash

# Версия скрипта: 1.0.0

echo ""
echo "Начинаю настройку сервера..."
echo ""

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "[*] ЭТОТ СКРИПТ ОБЯЗАТЕЛЬНО ДОЛЖЕН БЫТЬ ЗАПУЩЕН ЧЕРЕЗ ROOT/SUDO. Повтори установку с правами суперпользователя"
    echo ""
    exit 1
fi

echo ""
echo "Выбери опцию (вписав цифру и нажав enter):"
echo "1) Установить и настроить сервер"
echo "2) Удалить все настройки сервера"
echo ""

read -p "Введи номер опции [1/2]: " action_choice

if [ "$action_choice" == "2" ]; then
    echo ""
    echo "[*] Удаление всех прошлых настроек сервера..."
    echo ""

    # Остановка служб
    sudo systemctl stop openvpn@client1.service wg-quick@tun0.service dnsmasq.service apache2.service || true
    sudo systemctl disable openvpn@client1.service
    sudo systemctl disable wg-quick@tun0.service

    # Удаление папок OpenVPN и WireGuard
    sudo rm -rf /etc/openvpn
    sudo rm -rf /etc/wireguard

    # Удаление OpenVPN и WireGuard
    sudo apt-get purge wireguard -y
    sudo apt-get remove wireguard -y
    sudo apt-get autoremove wireguard
    sudo apt-get purge openvpn -y
    sudo apt-get remove openvpn -y
    sudo apt-get autoremove openvpn

    # Удаление сайта VPN
    sudo rm -rf /var/www/html

    # Удаление конфигурации DHCP
    sudo rm -f /etc/dnsmasq.conf

    # Удаление остаточных правил
    sudo iptables -t nat -D POSTROUTING -o tun0 -s 192.168.1.0/24 -j MASQUERADE || true
    sudo iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE || true
    sudo iptables-save > /etc/iptables/rules.v4

    echo ""
    echo "[*] Все настройки удалены. Можно запустить скрипт еще раз и выбрать первый пункт."
    echo ""
    exit 0
elif [ "$action_choice" == "1" ]; then
    echo ""
    echo "[*] Продолжается установка и настройка сервера..."
    echo ""
else
    echo "Неверный выбор. Пожалуйста, выбери 1 или 2 (ЦИФРАМИ)"
    exit 1
fi

# Установка программ
echo ""
echo "[*] Установка дополнительных программ и обновлений..."
echo ""
apt-get update && apt-get install -y htop net-tools mtr dnsmasq network-manager wireguard openvpn apache2 php git iptables-persistent openssh-server resolvconf speedtest-cli nload libapache2-mod-php wget ufw

# Получаем все интерфейсы, кроме lo
interfaces_and_addresses=$(ip -o link show | awk '$2 != "lo:" {print $2}' | sed 's/://' | nl)

# Формируем список интерфейсов с адресами
interfaces_and_addresses=$(ip -o -4 addr show | awk '{print $2 ": " $4}' | sed 's/\/.*//')
all_interfaces=$(ip -o link show | awk '$2 != "lo:" {print $2}' | sed 's/://')

# Собираем все интерфейсы и добавляем информацию о тех, которые не имеют IP-адреса
full_list=""
for interface in $all_interfaces; do
    if echo "$interfaces_and_addresses" | grep -q "$interface"; then
        ip_addr=$(echo "$interfaces_and_addresses" | grep "$interface" | awk '{print $2}')
        full_list+="$interface: $ip_addr\n"
    else
        full_list+="$interface: нет IP-адреса, ВОЗМОЖНО подойдет для локальной сети\n"
    fi
done

# Выводим список интерфейсов с адресами по номерам
echo "Сетевые адреса и интерфейсы:"
echo -e "$full_list" | nl
echo ""

# Запрос номера входящего интерфейса
read -p "Укажи свой ВХОДЯЩИЙ сетевой интерфейс, в который входит интернет от провайдера (ЦИФРАМИ): " input_interface_number

# Запрос номера выходящего интерфейса
read -p "Укажи свой ВЫХОДЯЩИЙ сетевой интерфейс, к которому будет подключена локальная сеть(ЦИФРАМИ): " output_interface_number

# Получаем имена входного и выходного сетевых интерфейсов по номерам
input_interface=$(echo -e "$full_list" | awk -v num="$input_interface_number" 'NR == num {print $1}')
output_interface=$(echo -e "$full_list" | awk -v num="$output_interface_number" 'NR == num {print $1}')

# Удаляем любые двоеточия в конце переменных, если они присутствуют
input_interface=${input_interface%:}
output_interface=${output_interface%:}

# Выводим выбранные интерфейсы
echo ""
echo "ВХОДЯЩИЙ сетевой интерфейс: $input_interface"
echo "ВЫХОДЯЩИЙ сетевой интерфейс: $output_interface"
echo ""

# Запрашиваем у пользователя, хочет ли он изменить стандартный локальный адрес
echo "Если ты не знаешь или ставишь единственный сервер, то лучше согласится и принять стандартный локальный IP-адрес"
echo "Впиши букву "y" чтобы согласиться изменить или "n" чтобы отказаться и оставить как есть"
read -p "Изменить стандартный локальный айпи адрес (192.168.1.1)? [y/n]: " change_local_ip

if [ "$change_local_ip" == "y" ]; then
    # Запрос нового локального IP-адреса
    read -p "Введи новый локальный IP-адрес например, 192.168.2.1 (ОБЯЗАТЕЛЬНО чтобы окончание было ТОЛЬКО .1 как в примере): " local_ip
    # Проверка корректности введенного IP-адреса
    if [[ ! $local_ip =~ ^192\.168\.[0-9]{1,3}\.1$ ]]; then
        echo "Неправильный IP-адрес. Пожалуйста, введите адрес в формате 192.168.X.1, чтобы В КОНЦЕ была единица"
        exit 1
    fi
else
    # Используем стандартный локальный IP-адрес
    local_ip="192.168.1.1"
fi

# Вывод вариантов настройки сетевых подключений
echo ""
echo "Настройка сетевых интерфейсов:"
echo "1) Получить IP-адрес и интернет по DHCP от провайдера или другого сервера"
echo "2) Статический IP-адрес по данным от провайдера"
echo "*Если не знаешь, то лучше выбирать 1-й вариант*"
echo ""

# Проверка настроек сетевых подключений
read -p "Выбери вариант (вписав цифру и нажав enter) [1/2] : " choice
echo ""

#  Внесение изменений в NETWORK
if [ "$choice" == "1" ]; then
    # Для DHCP
    cat <<EOF > /etc/network/interfaces
source /etc/network/interfaces.d/*

# LOOPBACK
auto lo
iface lo inet loopback

# Входящий интерфейс от провайдера
auto $input_interface
iface $input_interface inet dhcp

# Выходящий интерфейс в локальную сеть
auto $output_interface
iface $output_interface inet static
address $local_ip
netmask 255.255.255.0
EOF
elif [ "$choice" == "2" ]; then
    # Для статического адреса
    read -p "Введите IP-адрес: " address
    read -p "Введите подсеть (netmask): " netmask
    read -p "Введите шлюз: " gateway
    read -p "Введите DNS1: " dns1
    read -p "Введите DNS2: " dns2

    cat <<EOF > /etc/netplan/01-network-manager-all.yaml
source /etc/network/interfaces.d/*

# LOOPBACK
auto lo
iface lo inet loopback

# Входящий интерфейс от провайдера
auto $input_interface
iface $input_interface inet static
address $address
netmask $netmask
gateway $gateway
dns nameservers $dns1 $dns2

# Выходящий интерфейс в локальную сеть
auto $output_interface
iface $output_interface inet static
address $local_ip
netmask 255.255.255.0
EOF
else
    echo "Неправильный выбор."
    exit 1
fi


# Установка vSwitch если не установлен
sudo apt-get install openvswitch-switch -y
sudo systemctl start openvswitch-switch
sudo systemctl enable openvswitch-switch

echo ""
echo "[*] Сохраняю настройки для применения..."
echo ""
sudo systemctl restart networking
sleep 10

echo ""
echo "[*] Проверка выхода в интернет..."
echo ""
response=$(curl -s -o /dev/null -w "%{http_code}" http://www.google.com)

if [ "$response" -eq 200 ]; then
    echo ""
    echo "[*] Проверка выхода в интернет = УСПЕШНО."
    echo ""
else
    echo ""
    echo "[*] Ошибка: Интернет соединение недоступно. Пожалуйста, проверьте, что сервер подключен к сети и вы подвязали MAC-адрес оборудования у провайдера."
    echo ""
    exit 1
fi

# Настройка DNS
RESOLV_CONF="/etc/resolvconf/resolv.conf.d/base"
RESOLV_CONF2="/etc/resolv.conf"

# DNS сервера
DNS1="nameserver 8.8.8.8"
DNS2="nameserver 8.8.4.4"

# Проверка DNS серверов
grep -qxF "$DNS1" "$RESOLV_CONF" || echo "$DNS1" | sudo tee -a "$RESOLV_CONF"

# Проверка и добавление второго DNS сервера, если он отсутствует
grep -qxF "$DNS2" "$RESOLV_CONF" || echo "$DNS2" | sudo tee -a "$RESOLV_CONF"

# Проверка и добавление первого DNS сервера, если он отсутствует
grep -qxF "$DNS1" "$RESOLV_CONF2" || echo "$DNS1" | sudo tee -a "$RESOLV_CONF2"

# Проверка и добавление второго DNS сервера, если он отсутствует
grep -qxF "$DNS2" "$RESOLV_CONF2" || echo "$DNS2" | sudo tee -a "$RESOLV_CONF2"

sudo resolvconf -u

# Перезагрузка
sudo systemctl restart systemd-resolved

# Открывает доступ по SSH
echo ""
echo "[*] Открываю порт 22 для подключений по SSH..."
echo ""
sudo systemctl restart ssh
sudo ufw allow OpenSSH
sudo ufw allow 22

echo ""
echo "[*] Настройка DHCP сервера..."
echo ""

# Путь к конфигурационному файлу dnsmasq
config_file="/etc/dnsmasq.conf"

# Ввод данных в файл для DNS
cat <<EOF | sudo tee -a $config_file
listen-address=127.0.0.1,$local_ip
dhcp-range=${local_ip%.*}.10,${local_ip%.*}.254,12h
server=8.8.8.8
server=8.8.4.4
EOF

sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo systemctl restart dnsmasq
sudo systemctl enable dnsmasq


echo ""
echo "[*] Настраиваем MASQUERADE..."
echo ""

sudo sed -i '/^#.*net.ipv4.ip_forward/s/^#//' /etc/sysctl.conf
sudo sysctl -p
sudo iptables -t nat -A POSTROUTING -o tun0 -s $local_ip/24 -j MASQUERADE
sudo /etc/init.d/netfilter-persistent save

echo ""
echo "[*] Настройка VPN..."
echo ""
sudo sed -i '/^#\s*AUTOSTART="all"/s/^#\s*//' /etc/default/openvpn

echo ""
echo "[*] Установка сайта для добавления конфигов..."
echo ""
sudo chmod -R 755 /etc/openvpn
sudo chmod -R 755 /etc/wireguard
sudo chown -R www-data:www-data /etc/openvpn
sudo chown -R www-data:www-data /etc/wireguard
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop openvpn*, /bin/systemctl start openvpn*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop wg-quick*, /bin/systemctl start wg-quick*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl enable wg-quick*, /bin/systemctl disable wg-quick*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart openvpn@client1*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl start openvpn@client1*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl disable openvpn@client1*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl start wg-quick@tun0*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart wg-quick@tun0*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl disable wg-quick@tun0*" | sudo tee -a /etc/sudoers
echo "www-data ALL=(root) NOPASSWD: /usr/bin/id" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl" | sudo tee -a /etc/sudoers
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables-save > /etc/iptables/rules.v4
sudo iptables-save | sudo tee /etc/iptables/rules.v4
sudo service iptables restart
sudo rm -rf /var/www
sudo git clone https://github.com/Rostarc/VPN-Web-Installer.git /var/www/html

# Установка прав доступа к /var/www/html
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html

# Создание файла .htaccess
cat <<EOF | sudo tee /var/www/html/.htaccess
# Разрешаем доступ только с локального IP
<RequireAll>
    Require ip 192.168
</RequireAll>
EOF

# Настройка Apache для использования .htaccess
sudo a2enmod rewrite
sudo systemctl restart apache2

echo ""
echo "[*] Установка Завершена!"
echo ""
echo "Вы можете перейти на свой локальный сайт для легкой установки конфига"
echo "Например: ссылка http://$local_ip/ для входа на ваш сайт с локальной сети"
echo "Удачи ^_^"
echo ""
