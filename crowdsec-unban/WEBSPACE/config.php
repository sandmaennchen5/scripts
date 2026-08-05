<?php
declare(strict_types=1);

// Zentrale Einstellungen der Notfallseite. Diese Datei liegt absichtlich außerhalb von public/.
return [
    'page_title' => 'CrowdSec Notfall-Unban',
    'server_name' => 'Mein CrowdSec VPS',
    'server_description' => 'Produktivserver',
    'host' => '203.0.113.10', // Vor der Installation ersetzen.
    'port' => 22,
    'ssh_user' => 'rescue',
    'ssh_key' => __DIR__ . '/crowdsec_rescue',

    // Nur diese bereits in .htpasswd vorhandenen Benutzer dürfen admin.php öffnen.
    'admin_users' => ['admin'],
    'password_file' => __DIR__ . '/.htpasswd',
    'default_password_hash' => '{SHA}0DPiKuNIrrVmD8IUCuw1hQxNqZc=',

    // Nur feste IPs eigener, vertrauenswürdiger Reverse-Proxys eintragen.
    'trusted_proxies' => [],
];
