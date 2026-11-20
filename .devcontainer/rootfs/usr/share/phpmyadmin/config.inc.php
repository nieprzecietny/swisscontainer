<?php
// phpMyAdmin w devcontainerze: logowanie automatyczne kontem `dev` (tylko localhost).
// Hasło i blowfish_secret: /var/lib/phpmyadmin/devc-secrets.php (root:pma 0640, generowane przez container-init.sh).
declare(strict_types=1);

$devc = require '/var/lib/phpmyadmin/devc-secrets.php';

$cfg['blowfish_secret'] = sodium_hex2bin($devc['blowfish']);

$i = 1;
$cfg['Servers'][$i]['verbose'] = 'MariaDB (devcontainer)';
$cfg['Servers'][$i]['auth_type'] = 'config';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = '3306';
$cfg['Servers'][$i]['user'] = 'dev';
$cfg['Servers'][$i]['password'] = $devc['dev_password'];
$cfg['Servers'][$i]['AllowNoPassword'] = false;

$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';
$cfg['VersionCheck'] = false;
$cfg['SendErrorReports'] = 'never';
$cfg['ShowPhpInfo'] = false;
$cfg['ShowServerInfo'] = true;
