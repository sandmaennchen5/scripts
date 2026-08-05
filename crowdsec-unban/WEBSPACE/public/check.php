<?php
declare(strict_types=1);

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store, max-age=0');
header('X-Frame-Options: DENY');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'");

$baseDir = dirname(__DIR__);
$config = require $baseDir . '/config.php';
$pageTitle = (string) $config['page_title'];
$serverName = (string) $config['server_name'];
$serverDescription = (string) $config['server_description'];
$host = (string) $config['host'];
$port = (int) $config['port'];
$publicDir = __DIR__;
$keyFile = (string) $config['ssh_key'];
$passwordFile = $baseDir . '/.htpasswd';
$accessFile = $publicDir . '/.htaccess';
$rateFile = $baseDir . '/crowdsec_rescue_rate_limits.json';
$auditFile = $baseDir . '/crowdsec_rescue_audit.log';
$checks = [];

function addCheck(array &$checks, string $label, string $status, string $message): void
{
    $checks[] = ['label' => $label, 'status' => $status, 'message' => $message];
}

function modeOf(string $file): ?string
{
    $permissions = @fileperms($file);
    return $permissions === false ? null : substr(sprintf('%o', $permissions), -4);
}

function checkPrivateFile(array &$checks, string $label, string $file, int $minimumSize): void
{
    if (!is_file($file)) {
        addCheck($checks, $label, 'fail', 'Datei fehlt.');
        return;
    }
    if (!is_readable($file)) {
        addCheck($checks, $label, 'fail', 'Datei ist für PHP nicht lesbar.');
        return;
    }
    $size = filesize($file);
    $mode = modeOf($file);
    if ($size === false || $size < $minimumSize) {
        addCheck($checks, $label, 'fail', 'Datei ist leer oder auffällig klein.');
    } elseif ($mode !== null && (octdec($mode) & 0002) !== 0) {
        addCheck($checks, $label, 'fail', 'Datei ist für andere Benutzer beschreibbar (Modus ' . $mode . ').');
    } elseif ($mode !== null && (octdec($mode) & 0004) !== 0) {
        addCheck($checks, $label, 'warn', 'Lesbar, aber weltweit lesbar (Modus ' . $mode . '). 0600 wird empfohlen.');
    } else {
        addCheck($checks, $label, 'pass', 'Vorhanden, lesbar und Berechtigung ' . ($mode ?? 'nicht ermittelbar') . '.');
    }
}

function isOpenSshKey(string $content): bool
{
    $trimmed = trim($content);
    if (strpos($trimmed, '-----BEGIN OPENSSH PRIVATE KEY-----') !== 0
        || substr($trimmed, -strlen('-----END OPENSSH PRIVATE KEY-----')) !== '-----END OPENSSH PRIVATE KEY-----') return false;
    $body = str_replace(['-----BEGIN OPENSSH PRIVATE KEY-----', '-----END OPENSSH PRIVATE KEY-----'], '', $trimmed);
    $body = preg_replace('/\s+/', '', $body);
    $decoded = is_string($body) ? base64_decode($body, true) : false;
    return is_string($decoded) && strpos($decoded, "openssh-key-v1\0") === 0;
}

addCheck($checks, 'PHP-Version', version_compare(PHP_VERSION, '7.4.0', '>=') ? 'pass' : 'fail',
    PHP_VERSION . (version_compare(PHP_VERSION, '7.4.0', '>=') ? ' wird unterstützt.' : ' ist zu alt; mindestens 7.4 erforderlich.'));

$disabled = array_map('trim', explode(',', (string) ini_get('disable_functions')));
$execAvailable = function_exists('exec') && !in_array('exec', $disabled, true);
addCheck($checks, 'PHP-Funktion exec()', $execAvailable ? 'pass' : 'fail',
    $execAvailable ? 'Verfügbar.' : 'Fehlt oder wurde durch disable_functions gesperrt.');

$sshPath = '/usr/bin/ssh';
addCheck($checks, 'SSH-Programm', is_file($sshPath) && is_executable($sshPath) ? 'pass' : 'fail',
    is_file($sshPath) && is_executable($sshPath) ? 'Vorhanden und ausführbar.' : '/usr/bin/ssh fehlt oder ist nicht ausführbar.');

$https = (!empty($_SERVER['HTTPS']) && strtolower((string) $_SERVER['HTTPS']) !== 'off')
    || (int) ($_SERVER['SERVER_PORT'] ?? 0) === 443;
addCheck($checks, 'HTTPS', $https ? 'pass' : 'fail', $https ? 'Verbindung ist verschlüsselt.' : 'HTTPS wurde nicht erkannt.');

$authUser = $_SERVER['REMOTE_USER'] ?? $_SERVER['PHP_AUTH_USER'] ?? '';
addCheck($checks, 'HTTP-Anmeldung', $authUser !== '' ? 'pass' : 'warn',
    $authUser !== '' ? 'Angemeldeter Benutzer wurde erkannt.' : 'Kein Benutzername in der PHP-Umgebung erkannt; Basic Auth prüfen.');

$remoteIp = $_SERVER['REMOTE_ADDR'] ?? '';
addCheck($checks, 'Besucher-IP', filter_var($remoteIp, FILTER_VALIDATE_IP) !== false ? 'pass' : 'fail',
    filter_var($remoteIp, FILTER_VALIDATE_IP) !== false ? 'Gültige IPv4- oder IPv6-Adresse erkannt.' : 'Keine gültige REMOTE_ADDR erkannt.');

checkPrivateFile($checks, 'Privater SSH-Schlüssel', $keyFile, 100);
if (is_readable($keyFile)) {
    $keyContent = file_get_contents($keyFile);
    $validKey = is_string($keyContent) && isOpenSshKey($keyContent);
    addCheck($checks, 'Schlüsselformat', $validKey ? 'pass' : 'fail',
        $validKey ? 'Vollständiger OpenSSH-Privatschlüssel erkannt.' : 'Kein vollständiger OpenSSH-Privatschlüssel erkannt.');
}
checkPrivateFile($checks, '.htpasswd außerhalb public/', $passwordFile, 20);
addCheck($checks, '.htpasswd-Schreibzugriff', is_writable($passwordFile) ? 'pass' : 'warn',
    is_writable($passwordFile) ? 'Die Benutzerverwaltung darf Passwörter sicher aktualisieren.' : 'Nicht beschreibbar; admin.php kann keine Benutzeränderungen speichern.');
if (is_readable($passwordFile)) {
    $passwordData = (string) file_get_contents($passwordFile);
    $defaultActive = strpos($passwordData, 'admin:{SHA}0DPiKuNIrrVmD8IUCuw1hQxNqZc=') !== false;
    addCheck($checks, 'Standardpasswort', $defaultActive ? 'fail' : 'pass',
        $defaultActive ? 'admin/admin ist noch aktiv und muss sofort in admin.php geändert werden.' : 'Das veröffentlichte Startpasswort ist nicht mehr aktiv.');
}

if (!is_readable($accessFile)) {
    addCheck($checks, '.htaccess', 'fail', 'Datei fehlt oder ist nicht lesbar.');
} else {
    $access = (string) file_get_contents($accessFile);
    $directives = stripos($access, 'AuthType Basic') !== false
        && stripos($access, 'Require valid-user') !== false
        && stripos($access, 'Options -Indexes') !== false;
    addCheck($checks, '.htaccess', $directives ? 'pass' : 'fail',
        $directives ? 'Basic Auth und Verzeichnis-Schutz sind eingetragen.' : 'Eine erforderliche Schutzdirektive fehlt.');
}

addCheck($checks, 'Datenverzeichnis', is_writable($baseDir) ? 'pass' : 'fail',
    is_writable($baseDir) ? 'PHP darf Audit- und Rate-Limit-Dateien anlegen.' : 'Nicht beschreibbar; Verwaltungsaktionen werden blockiert.');

foreach ([$rateFile => 'Rate-Limit-Datei', $auditFile => 'Audit-Protokoll'] as $file => $label) {
    if (!file_exists($file)) {
        addCheck($checks, $label, 'info', 'Wird bei der ersten Aktion automatisch angelegt.');
    } else {
        $mode = modeOf($file);
        $secure = is_readable($file) && is_writable($file) && ($mode === null || (octdec($mode) & 0077) === 0);
        addCheck($checks, $label, $secure ? 'pass' : 'warn',
            $secure ? 'Les- und schreibbar; Berechtigung ' . ($mode ?? 'nicht ermittelbar') . '.' : 'Sollte les-/schreibbar und auf Modus 0600 gesetzt sein; aktuell ' . ($mode ?? 'unbekannt') . '.');
    }
}

$home = (string) getenv('HOME');
$knownHosts = $home !== '' ? $home . '/.ssh/known_hosts' : '';
$hostToken = '[' . $host . ']:' . $port;
if ($knownHosts === '' || !is_readable($knownHosts)) {
    addCheck($checks, 'SSH-Hostschlüssel', 'fail', 'known_hosts ist für PHP nicht lesbar. StrictHostKeyChecking wird fehlschlagen.');
} else {
    $known = (string) file_get_contents($knownHosts);
    addCheck($checks, 'SSH-Hostschlüssel', strpos($known, $hostToken) !== false ? 'pass' : 'warn',
        strpos($known, $hostToken) !== false ? 'Eintrag für VPS und SSH-Port gefunden.' : 'Kein Klartext-Eintrag gefunden; bei gehashten Einträgen bitte SSH-Verbindung praktisch testen.');
}

$counts = ['pass' => 0, 'warn' => 0, 'fail' => 0, 'info' => 0];
foreach ($checks as $check) $counts[$check['status']]++;
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars($pageTitle . ' – Webspace-Prüfung', ENT_QUOTES, 'UTF-8') ?></title>
<style>
body{font-family:Arial,sans-serif;max-width:900px;margin:40px auto;padding:0 18px;color:#202124;line-height:1.45}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:11px;border-bottom:1px solid #ddd;vertical-align:top}th:first-child{width:27%}.pass{color:#137333}.warn{color:#9a6700}.fail{color:#b42318}.info{color:#475467}.summary{padding:14px;background:#f5f5f5;border-radius:6px;margin-bottom:20px}.badge{font-weight:bold;white-space:nowrap}a{color:#174ea6}
</style>
</head>
<body>
<h1>🩺 CrowdSec Webspace-Prüfung</h1>
<p><strong>Server:</strong> <?= htmlspecialchars($serverName, ENT_QUOTES, 'UTF-8') ?><?php if ($serverDescription !== ''): ?> · <?= htmlspecialchars($serverDescription, ENT_QUOTES, 'UTF-8') ?><?php endif; ?></p>
<div class="summary"><strong>Ergebnis:</strong> <?= $counts['pass'] ?> OK · <?= $counts['warn'] ?> Warnungen · <?= $counts['fail'] ?> Fehler · <?= $counts['info'] ?> Hinweise</div>
<table><thead><tr><th>Prüfung</th><th>Status</th><th>Ergebnis</th></tr></thead><tbody>
<?php foreach ($checks as $check): ?>
<tr><th><?= htmlspecialchars($check['label'], ENT_QUOTES, 'UTF-8') ?></th><td class="badge <?= $check['status'] ?>"><?= ['pass'=>'✅ OK','warn'=>'⚠️ Warnung','fail'=>'❌ Fehler','info'=>'ℹ️ Hinweis'][$check['status']] ?></td><td><?= htmlspecialchars($check['message'], ENT_QUOTES, 'UTF-8') ?></td></tr>
<?php endforeach; ?>
</tbody></table>
<p><a href="index.php">Zurück zur Notfallseite</a></p>
<p class="info">Diese Seite verändert keine Dateien und führt keine CrowdSec-Befehle aus. Nach erfolgreicher Einrichtung kann sie umbenannt oder entfernt werden.</p>
</body>
</html>
