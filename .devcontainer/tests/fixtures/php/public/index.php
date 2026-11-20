<?php
// Fixture verify.sh (etap 4): Apache + PHP-FPM + .htaccess (mod_rewrite).
header('Content-Type: text/plain; charset=utf-8');
echo "devc-fixture-php v1\n";
echo 'route=' . ($_GET['route'] ?? '') . "\n";
echo 'sapi=' . PHP_SAPI . "\n";
echo 'user=' . (function_exists('posix_geteuid') ? posix_getpwuid(posix_geteuid())['name'] : get_current_user()) . "\n";
