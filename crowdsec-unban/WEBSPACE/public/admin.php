<?php
declare(strict_types=1);

session_set_cookie_params(['secure' => true, 'httponly' => true, 'samesite' => 'Strict']);
session_start();
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store, max-age=0');
header('X-Frame-Options: DENY');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'");
header('Referrer-Policy: no-referrer');

$config = require dirname(__DIR__) . '/config.php';
$pageTitle = (string) $config['page_title'];
$passwordFile = (string) $config['password_file'];
$keyFile = (string) $config['ssh_key'];
$host = (string) $config['host'];
$port = (int) $config['port'];
$sshUser = (string) $config['ssh_user'];
$adminUsers = is_array($config['admin_users'] ?? null) ? $config['admin_users'] : [];
$currentUser = $_SERVER['REMOTE_USER'] ?? $_SERVER['PHP_AUTH_USER'] ?? '';

if ($currentUser === '' || !in_array($currentUser, $adminUsers, true)) {
    http_response_code(403);
    exit('Zugriff verweigert. Dieser Benutzer ist nicht als Administrator eingetragen.');
}

if (empty($_SESSION['admin_csrf_token'])) {
    $_SESSION['admin_csrf_token'] = bin2hex(random_bytes(32));
}

function readUsers(string $file): array
{
    if (!is_readable($file)) return [];
    $users = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        $parts = explode(':', $line, 2);
        if (count($parts) === 2 && $parts[0] !== '') $users[$parts[0]] = $parts[1];
    }
    ksort($users, SORT_NATURAL | SORT_FLAG_CASE);
    return $users;
}

function writeUsers(string $file, array $users): bool
{
    $directory = dirname($file);
    $temporary = @tempnam($directory, '.htpasswd-');
    if ($temporary === false) return false;
    ksort($users, SORT_NATURAL | SORT_FLAG_CASE);
    $lines = [];
    foreach ($users as $name => $hash) $lines[] = $name . ':' . $hash;
    $content = implode("\n", $lines) . "\n";

    $handle = @fopen($temporary, 'wb');
    if ($handle === false || !flock($handle, LOCK_EX)) {
        if (is_resource($handle)) fclose($handle);
        @unlink($temporary);
        return false;
    }
    $written = fwrite($handle, $content) === strlen($content);
    fflush($handle);
    flock($handle, LOCK_UN);
    fclose($handle);
    @chmod($temporary, 0600);
    if (!$written) {
        @unlink($temporary);
        return false;
    }

    if (is_file($file)) {
        @copy($file, $file . '.backup');
        @chmod($file . '.backup', 0600);
    }
    if (!@rename($temporary, $file)) {
        @unlink($temporary);
        return false;
    }
    @chmod($file, 0600);
    return true;
}

function validUsername(string $username): bool
{
    return preg_match('/\A[A-Za-z0-9._-]{1,64}\z/', $username) === 1;
}

function validPassword(string $password): bool
{
    return strlen($password) >= 12 && strlen($password) <= 200;
}

function validPrivateKey(string $content): bool
{
    $trimmed = trim($content);
    if (strlen($trimmed) < 100 || strlen($trimmed) > 65536 || strpos($trimmed, "\0") !== false
        || strpos($trimmed, '-----BEGIN OPENSSH PRIVATE KEY-----') !== 0
        || substr($trimmed, -strlen('-----END OPENSSH PRIVATE KEY-----')) !== '-----END OPENSSH PRIVATE KEY-----') return false;
    $body = str_replace(['-----BEGIN OPENSSH PRIVATE KEY-----', '-----END OPENSSH PRIVATE KEY-----'], '', $trimmed);
    $body = preg_replace('/\s+/', '', $body);
    $decoded = is_string($body) ? base64_decode($body, true) : false;
    return is_string($decoded) && strpos($decoded, "openssh-key-v1\0") === 0;
}

function writePrivateKey(string $file, string $content): bool
{
    $temporary = @tempnam(dirname($file), '.ssh-key-');
    if ($temporary === false) return false;
    $normalized = str_replace(["\r\n", "\r"], "\n", trim($content)) . "\n";
    if (@file_put_contents($temporary, $normalized, LOCK_EX) !== strlen($normalized)) {
        @unlink($temporary);
        return false;
    }
    @chmod($temporary, 0600);
    if (is_file($file)) {
        @copy($file, $file . '.backup');
        @chmod($file . '.backup', 0600);
    }
    if (!@rename($temporary, $file)) {
        @unlink($temporary);
        return false;
    }
    @chmod($file, 0600);
    return true;
}

function runSshStatus(string $ip, string $host, int $port, string $user, string $key, ?int &$exitCode): string
{
    $command = sprintf(
        '/usr/bin/ssh -p %d -i %s -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes %s@%s %s 2>&1',
        $port,
        escapeshellarg($key),
        escapeshellarg($user),
        escapeshellarg($host),
        escapeshellarg('STATUS ' . $ip)
    );
    $output = [];
    exec($command, $output, $exitCode);
    return implode("\n", $output);
}

function adminClientIp(array $trustedProxies): string
{
    $remote = $_SERVER['REMOTE_ADDR'] ?? '';
    if (!in_array($remote, $trustedProxies, true)) return $remote;
    $forwarded = array_map('trim', explode(',', $_SERVER['HTTP_X_FORWARDED_FOR'] ?? ''));
    for ($i = count($forwarded) - 1; $i >= 0; $i--) {
        if (filter_var($forwarded[$i], FILTER_VALIDATE_IP) !== false
            && !in_array($forwarded[$i], $trustedProxies, true)) return $forwarded[$i];
    }
    return $remote;
}

$message = null;
$error = null;
$users = readUsers($passwordFile);
$defaultPasswordHash = (string) ($config['default_password_hash'] ?? '');
$showKeyEditor = false;
$keyContent = '';
$sshTestResult = null;
$sshTestExitCode = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $csrfValid = isset($_POST['csrf_token']) && is_string($_POST['csrf_token'])
        && hash_equals($_SESSION['admin_csrf_token'], $_POST['csrf_token']);
    $operation = $_POST['operation'] ?? '';
    $username = trim((string) ($_POST['username'] ?? ''));
    $lockHandle = null;
    $userOperation = in_array($operation, ['add', 'change', 'delete'], true);
    $lockReady = !$userOperation;

    if ($csrfValid && $userOperation) {
        $lockHandle = @fopen($passwordFile . '.lock', 'c');
        $lockReady = is_resource($lockHandle) && flock($lockHandle, LOCK_EX);
        if ($lockReady) {
            @chmod($passwordFile . '.lock', 0600);
            $users = readUsers($passwordFile);
        }
    }

    if (!$csrfValid) {
        $error = 'Sicherheitsprüfung fehlgeschlagen. Bitte Seite neu laden.';
    } elseif (!$lockReady) {
        $error = 'Die Passwortdatei ist gerade nicht sicher verfügbar.';
    } elseif ($operation === 'key_reveal') {
        if (($_POST['key_confirmation'] ?? '') !== 'SCHLÜSSEL ANZEIGEN') {
            $error = 'Die Bestätigung zum Anzeigen des Schlüssels stimmt nicht.';
        } elseif (!is_file($keyFile)) {
            $keyContent = '';
            $showKeyEditor = true;
            $message = 'Noch kein Schlüssel vorhanden. Ein neuer OpenSSH-Schlüssel kann eingefügt werden.';
        } elseif (!is_readable($keyFile)) {
            $error = 'Der private Schlüssel ist für PHP nicht lesbar.';
        } else {
            $content = file_get_contents($keyFile);
            if (!is_string($content)) $error = 'Der private Schlüssel konnte nicht gelesen werden.';
            else {
                $keyContent = $content;
                $showKeyEditor = true;
                $message = 'Privater Schlüssel wurde zum Bearbeiten eingeblendet.';
            }
        }
    } elseif ($operation === 'key_save') {
        $keyContent = (string) ($_POST['private_key'] ?? '');
        $showKeyEditor = true;
        if (($_POST['save_confirmation'] ?? '') !== 'SCHLÜSSEL SPEICHERN') {
            $error = 'Die Bestätigung zum Speichern des Schlüssels stimmt nicht.';
        } elseif (!validPrivateKey($keyContent)) {
            $error = 'Es wurde kein vollständiger OpenSSH-Privatschlüssel erkannt.';
        } elseif (writePrivateKey($keyFile, $keyContent)) {
            $message = 'Privater Schlüssel wurde gespeichert; der vorherige Schlüssel liegt als Sicherung daneben.';
            $showKeyEditor = false;
            $keyContent = '';
        } else {
            $error = 'Der private Schlüssel konnte nicht sicher gespeichert werden.';
        }
    } elseif ($operation === 'ssh_test') {
        $trustedProxies = is_array($config['trusted_proxies'] ?? null) ? $config['trusted_proxies'] : [];
        $remoteIp = adminClientIp($trustedProxies);
        $now = time();
        $recentTests = array_values(array_filter($_SESSION['ssh_test_times'] ?? [], static function ($time) use ($now): bool {
            return is_int($time) && $time > $now - 60;
        }));
        if (count($recentTests) >= 3) {
            $error = 'Zu viele SSH-Tests. Bitte eine Minute warten.';
        } elseif (filter_var($remoteIp, FILTER_VALIDATE_IP) === false) {
            $error = 'Für den SSH-Test wurde keine gültige Besucher-IP erkannt.';
        } else {
            $recentTests[] = $now;
            $_SESSION['ssh_test_times'] = $recentTests;
            $sshTestResult = runSshStatus($remoteIp, $host, $port, $sshUser, $keyFile, $sshTestExitCode);
            if ($sshTestExitCode === 0) $message = 'SSH-Verbindung und CrowdSec-Statusabfrage waren erfolgreich.';
            else $error = 'Der SSH-Test ist fehlgeschlagen.';
        }
    } elseif ($userOperation && !validUsername($username)) {
        $error = 'Der Benutzername darf nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich enthalten.';
    } elseif ($operation === 'add' || $operation === 'change') {
        $password = (string) ($_POST['password'] ?? '');
        $confirmation = (string) ($_POST['password_confirmation'] ?? '');
        if ($password !== $confirmation) {
            $error = 'Die Passwörter stimmen nicht überein.';
        } elseif (!validPassword($password)) {
            $error = 'Das Passwort muss zwischen 12 und 200 Zeichen lang sein.';
        } elseif ($operation === 'add' && isset($users[$username])) {
            $error = 'Dieser Benutzer existiert bereits.';
        } elseif ($operation === 'change' && !isset($users[$username])) {
            $error = 'Dieser Benutzer wurde nicht gefunden.';
        } else {
            $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
            if (!is_string($hash)) {
                $error = 'Das Passwort konnte nicht sicher verarbeitet werden.';
            } else {
                $users[$username] = $hash;
            }
            if ($error === null && writeUsers($passwordFile, $users)) {
                $message = $operation === 'add' ? 'Benutzer wurde angelegt.' : 'Passwort wurde geändert.';
            } elseif ($error === null) {
                $error = '.htpasswd konnte nicht sicher gespeichert werden.';
            }
        }
    } elseif ($operation === 'delete') {
        if ($username === $currentUser) {
            $error = 'Das aktuell angemeldete Administratorkonto kann nicht selbst gelöscht werden.';
        } elseif (!isset($users[$username])) {
            $error = 'Dieser Benutzer wurde nicht gefunden.';
        } elseif (($_POST['delete_confirmation'] ?? '') !== $username) {
            $error = 'Zur Bestätigung muss der Benutzername exakt eingegeben werden.';
        } else {
            unset($users[$username]);
            if (writeUsers($passwordFile, $users)) $message = 'Benutzer wurde gelöscht.';
            else $error = '.htpasswd konnte nicht sicher gespeichert werden.';
        }
    }
    if ($lockReady) flock($lockHandle, LOCK_UN);
    if (is_resource($lockHandle)) fclose($lockHandle);
    $users = readUsers($passwordFile);
}

$csrf = htmlspecialchars($_SESSION['admin_csrf_token'], ENT_QUOTES, 'UTF-8');
$defaultPasswordActive = $defaultPasswordHash !== ''
    && isset($users['admin'])
    && hash_equals($defaultPasswordHash, $users['admin']);
$keyExists = is_file($keyFile);
$keySize = $keyExists ? filesize($keyFile) : false;
$keyModeRaw = $keyExists ? fileperms($keyFile) : false;
$keyPermissions = $keyModeRaw === false ? 'unbekannt' : substr(sprintf('%o', $keyModeRaw), -4);
?>
<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars($pageTitle, ENT_QUOTES, 'UTF-8') ?> – Benutzerverwaltung</title>
<style>
body{font-family:Arial,sans-serif;max-width:900px;margin:40px auto;padding:0 18px;color:#202124;line-height:1.45}.box{border:1px solid #bbb;border-radius:7px;padding:18px;margin:18px 0}.ok{background:#ecfdf3;border-color:#28a745}.error{background:#fef3f2;border-color:#dc3545}label{display:block;font-weight:bold;margin-top:11px}input{font-size:16px;padding:9px;width:min(420px,92%)}button{margin-top:14px;padding:10px 17px;font-size:16px;cursor:pointer}.danger{background:#7a271a;color:#fff;border:1px solid #7a271a;border-radius:5px}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:9px;border-bottom:1px solid #ddd}.forms{display:grid;grid-template-columns:1fr 1fr;gap:18px}@media(max-width:700px){.forms{grid-template-columns:1fr}}.muted{color:#666;font-size:14px}
textarea{font-family:monospace;font-size:15px;padding:10px;width:100%;min-height:320px;box-sizing:border-box;white-space:pre;overflow:auto}pre{background:#f5f5f5;padding:13px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere}.warn{background:#fff8e1;border-color:#d49b00}
</style></head><body>
<h1>👤 Benutzerverwaltung</h1>
<p>Angemeldet als <strong><?= htmlspecialchars($currentUser, ENT_QUOTES, 'UTF-8') ?></strong></p>
<?php if ($message !== null): ?><div class="box ok">✅ <?= htmlspecialchars($message, ENT_QUOTES, 'UTF-8') ?></div><?php endif; ?>
<?php if ($error !== null): ?><div class="box error">❌ <?= htmlspecialchars($error, ENT_QUOTES, 'UTF-8') ?></div><?php endif; ?>
<?php if ($defaultPasswordActive): ?><div class="box error"><strong>⚠️ Unsicheres Startpasswort aktiv:</strong> Ändere das Passwort des Benutzers <code>admin</code> jetzt sofort. Das veröffentlichte Startpasswort darf nicht dauerhaft verwendet werden.</div><?php endif; ?>

<div class="box"><h2>Vorhandene Benutzer</h2><table><tr><th>Benutzername</th><th>Rolle</th></tr>
<?php foreach (array_keys($users) as $username): ?><tr><td><?= htmlspecialchars($username, ENT_QUOTES, 'UTF-8') ?></td><td><?= in_array($username, $adminUsers, true) ? 'Administrator' : 'Benutzer' ?></td></tr><?php endforeach; ?>
</table></div>

<div class="forms">
<form method="post" class="box"><h2>Benutzer anlegen</h2><input type="hidden" name="csrf_token" value="<?= $csrf ?>"><input type="hidden" name="operation" value="add">
<label>Benutzername</label><input name="username" required maxlength="64" autocomplete="off">
<label>Passwort</label><input type="password" name="password" required minlength="12" maxlength="200" autocomplete="new-password">
<label>Passwort wiederholen</label><input type="password" name="password_confirmation" required minlength="12" maxlength="200" autocomplete="new-password">
<button type="submit">Benutzer anlegen</button></form>

<form method="post" class="box"><h2>Passwort ändern</h2><input type="hidden" name="csrf_token" value="<?= $csrf ?>"><input type="hidden" name="operation" value="change">
<label>Benutzername</label><input name="username" required maxlength="64" autocomplete="off">
<label>Neues Passwort</label><input type="password" name="password" required minlength="12" maxlength="200" autocomplete="new-password">
<label>Passwort wiederholen</label><input type="password" name="password_confirmation" required minlength="12" maxlength="200" autocomplete="new-password">
<button type="submit">Passwort ändern</button></form>
</div>

<form method="post" class="box"><h2>Benutzer löschen</h2><input type="hidden" name="csrf_token" value="<?= $csrf ?>"><input type="hidden" name="operation" value="delete">
<label>Benutzername</label><input name="username" required maxlength="64" autocomplete="off">
<label>Benutzername zur Bestätigung wiederholen</label><input name="delete_confirmation" required maxlength="64" autocomplete="off">
<button type="submit" class="danger">Benutzer löschen</button></form>

<p class="muted">Neue Benutzer erhalten normalen Zugang zur Notfallseite. Administratoren werden ausschließlich über <code>admin_users</code> in <code>config.php</code> festgelegt. Die letzte vorherige Passwortdatei liegt als <code>.htpasswd.backup</code> außerhalb des Webroots.</p>
<div class="box">
<h2>🔑 SSH-Schlüssel</h2>
<table>
<tr><th>Status</th><td><?= $keyExists ? 'Vorhanden' : 'Fehlt' ?></td></tr>
<tr><th>Größe</th><td><?= $keySize === false ? '–' : (int) $keySize . ' Bytes' ?></td></tr>
<tr><th>Berechtigung</th><td><?= htmlspecialchars($keyPermissions, ENT_QUOTES, 'UTF-8') ?><?= $keyPermissions === '0600' ? ' (empfohlen)' : '' ?></td></tr>
</table>
<div class="box warn"><strong>Achtung:</strong> Wer diesen Schlüssel sieht, kann ihn kopieren. Nur auf einem vertrauenswürdigen Gerät anzeigen und danach die Browserseite schließen.</div>
<form method="post"><input type="hidden" name="csrf_token" value="<?= $csrf ?>"><input type="hidden" name="operation" value="key_reveal">
<label>Zur Anzeige exakt „SCHLÜSSEL ANZEIGEN“ eingeben</label><input name="key_confirmation" required autocomplete="off">
<button type="submit" class="danger">Schlüssel anzeigen und bearbeiten</button></form>
</div>

<?php if ($showKeyEditor): ?>
<form method="post" class="box error"><h2>Privaten Schlüssel bearbeiten</h2>
<input type="hidden" name="csrf_token" value="<?= $csrf ?>"><input type="hidden" name="operation" value="key_save">
<label>OpenSSH-Privatschlüssel</label><textarea name="private_key" required spellcheck="false" autocomplete="off"><?= htmlspecialchars($keyContent, ENT_QUOTES, 'UTF-8') ?></textarea>
<label>Zur Speicherung exakt „SCHLÜSSEL SPEICHERN“ eingeben</label><input name="save_confirmation" required autocomplete="off">
<button type="submit" class="danger">Schlüssel sicher speichern</button>
</form>
<?php endif; ?>

<div class="box"><h2>🔌 SSH-Verbindung prüfen</h2>
<p>Führt ausschließlich <code>STATUS &lt;deine IP&gt;</code> aus. Es werden keine Sperren gelöscht.</p>
<form method="post"><input type="hidden" name="csrf_token" value="<?= $csrf ?>"><input type="hidden" name="operation" value="ssh_test"><button type="submit">SSH und CrowdSec prüfen</button></form>
<?php if ($sshTestResult !== null): ?><p><strong>Rückgabecode:</strong> <?= (int) $sshTestExitCode ?></p><pre><?= htmlspecialchars($sshTestResult, ENT_QUOTES, 'UTF-8') ?></pre><?php endif; ?>
</div>
<p><a href="index.php">Zurück zur Notfallseite</a></p>
</body></html>
