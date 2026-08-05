<?php
declare(strict_types=1);

session_set_cookie_params([
    'secure' => true,
    'httponly' => true,
    'samesite' => 'Strict',
]);
session_start();
header('Content-Type: text/html; charset=utf-8');
header('X-Frame-Options: DENY');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'");
header('Referrer-Policy: no-referrer');

$config = require dirname(__DIR__) . '/config.php';
$pageTitle = (string) $config['page_title'];
$serverName = (string) $config['server_name'];
$serverDescription = (string) $config['server_description'];
$host = (string) $config['host'];
$port = (int) $config['port'];
$user = (string) $config['ssh_user'];
$key = (string) $config['ssh_key'];
$dataDir = dirname(__DIR__);

$trustedProxies = is_array($config['trusted_proxies'] ?? null) ? $config['trusted_proxies'] : [];

function resolveClientIp(array $trustedProxies): string
{
    $remote = $_SERVER['REMOTE_ADDR'] ?? '';
    if (filter_var($remote, FILTER_VALIDATE_IP) === false || !in_array($remote, $trustedProxies, true)) {
        return $remote;
    }

    $forwarded = array_map('trim', explode(',', $_SERVER['HTTP_X_FORWARDED_FOR'] ?? ''));
    for ($i = count($forwarded) - 1; $i >= 0; $i--) {
        if (filter_var($forwarded[$i], FILTER_VALIDATE_IP) !== false
            && !in_array($forwarded[$i], $trustedProxies, true)) {
            return $forwarded[$i];
        }
    }
    return $remote;
}

function runRescueCommand(string $verb, string $ip, string $host, int $port, string $user, string $key, ?int &$exitCode): string
{
    $remoteCommand = $verb === 'UNBAN_ALL' ? $verb : $verb . ' ' . $ip;
    $command = sprintf(
        '/usr/bin/ssh -p %d -i %s -o BatchMode=yes -o ConnectTimeout=10 '
        . '-o StrictHostKeyChecking=yes %s@%s %s 2>&1',
        $port,
        escapeshellarg($key),
        escapeshellarg($user),
        escapeshellarg($host),
        escapeshellarg($remoteCommand)
    );
    $output = [];
    exec($command, $output, $exitCode);
    return implode("\n", $output);
}

function jsonList(string $json, string $container): ?array
{
    $decoded = json_decode($json, true);
    if (!is_array($decoded)) {
        return null;
    }
    if (isset($decoded[$container]) && is_array($decoded[$container])) {
        return $decoded[$container];
    }
    $isList = $decoded === [] || array_keys($decoded) === range(0, count($decoded) - 1);
    return $isList ? $decoded : [];
}

function rateLimit(string $file, string $identity, string $action, int $limit, int $seconds): bool
{
    $handle = @fopen($file, 'c+');
    if ($handle === false || !flock($handle, LOCK_EX)) {
        if (is_resource($handle)) fclose($handle);
        return false; // Bei defektem Schutz keine Verwaltungsaktion ausführen.
    }
    @chmod($file, 0600);
    $raw = stream_get_contents($handle);
    $data = json_decode($raw ?: '{}', true);
    if (!is_array($data)) $data = [];
    $now = time();
    $key = hash('sha256', $identity . '|' . $action);
    $recent = array_values(array_filter($data[$key] ?? [], static function ($time) use ($now, $seconds): bool {
        return is_int($time) && $time > $now - $seconds;
    }));
    $allowed = count($recent) < $limit;
    if ($allowed) $recent[] = $now;
    $data[$key] = $recent;
    ftruncate($handle, 0);
    rewind($handle);
    fwrite($handle, json_encode($data));
    fflush($handle);
    flock($handle, LOCK_UN);
    fclose($handle);
    return $allowed;
}

function audit(string $file, string $webUser, string $ip, string $action, int $exitCode): void
{
    $cleanUser = preg_replace('/[^a-zA-Z0-9_.@-]/', '_', $webUser) ?: 'unbekannt';
    $line = sprintf("%s user=%s ip=%s action=%s exit=%d\n", gmdate('c'), $cleanUser, $ip, $action, $exitCode);
    if (@file_put_contents($file, $line, FILE_APPEND | LOCK_EX) === false) {
        error_log('crowdsec-rescue-audit ' . trim($line));
    } else {
        @chmod($file, 0600);
    }
}

function field(array $item, array $names, string $fallback = '–'): string
{
    foreach ($names as $name) {
        if (isset($item[$name]) && $item[$name] !== '') {
            if (is_array($item[$name])) {
                $encoded = json_encode($item[$name], JSON_UNESCAPED_SLASHES);
                return is_string($encoded) ? $encoded : $fallback;
            }
            return (string) $item[$name];
        }
    }
    return $fallback;
}

function sourceDetails(array $alert): array
{
    $source = isset($alert['source']) && is_array($alert['source']) ? $alert['source'] : [];
    return [
        'IP-Adresse' => field($source, ['ip']),
        'Anbieter' => field($source, ['as_name']),
        'ASN' => field($source, ['as_number']),
        'Land' => field($source, ['cn']),
    ];
}

if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

$clientIp = resolveClientIp($trustedProxies);
$validIp = filter_var($clientIp, FILTER_VALIDATE_IP) !== false;
$webUser = $_SERVER['REMOTE_USER'] ?? $_SERVER['PHP_AUTH_USER'] ?? 'unbekannt';
$adminUsers = is_array($config['admin_users'] ?? null) ? $config['admin_users'] : [];
$isAdmin = in_array($webUser, $adminUsers, true);
$action = $_POST['action'] ?? null;
$showDeleteAllConfirmation = false;
$result = null;
$exitCode = null;
$decisions = [];
$alerts = [];
$statusError = null;
$alertsWarning = null;
$requestError = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $csrfValid = isset($_POST['csrf_token'])
        && is_string($_POST['csrf_token'])
        && hash_equals($_SESSION['csrf_token'], $_POST['csrf_token']);

    if (!$csrfValid) {
        $requestError = 'Sicherheitsprüfung fehlgeschlagen. Bitte Seite neu laden.';
    } elseif (!$validIp) {
        $requestError = 'Die Besucher-IP konnte nicht sicher erkannt werden.';
    } elseif ($action === 'confirm_all') {
        if (!$isAdmin) $requestError = 'Nur Administratoren dürfen alle CrowdSec-Sperren löschen.';
        else $showDeleteAllConfirmation = true;
    } elseif (in_array($action, ['status', 'unban', 'unban_all'], true)) {
        $limits = [
            'status' => [5, 60],
            'unban' => [2, 60],
            'unban_all' => [1, 300],
        ];
        [$limit, $seconds] = $limits[$action];
        $identity = $webUser . '|' . $clientIp;

        if ($action === 'unban_all' && !$isAdmin) {
            $requestError = 'Nur Administratoren dürfen alle CrowdSec-Sperren löschen.';
            audit($dataDir . '/crowdsec_rescue_audit.log', $webUser, $clientIp, 'unban_all_forbidden', 403);
        } elseif ($action === 'unban_all' && ($_POST['confirmation'] ?? '') !== 'ALLE LÖSCHEN') {
            $requestError = 'Die Bestätigung für das Löschen aller Sperren stimmt nicht.';
            $showDeleteAllConfirmation = true;
            audit($dataDir . '/crowdsec_rescue_audit.log', $webUser, $clientIp, 'unban_all_bad_confirmation', 400);
        } elseif (!rateLimit($dataDir . '/crowdsec_rescue_rate_limits.json', $identity, $action, $limit, $seconds)) {
            $requestError = 'Zu viele Aufrufe. Bitte später erneut versuchen.';
            audit($dataDir . '/crowdsec_rescue_audit.log', $webUser, $clientIp, $action . '_rate_limited', 429);
        } else {
            $verb = $action === 'status' ? 'STATUS' : ($action === 'unban_all' ? 'UNBAN_ALL' : 'UNBAN');
            $result = runRescueCommand($verb, $clientIp, $host, $port, $user, $key, $exitCode);
            audit($dataDir . '/crowdsec_rescue_audit.log', $webUser, $clientIp, $action, (int) $exitCode);

            if ($action === 'status' && $exitCode === 0) {
                $parsed = jsonList($result, 'decisions');
                if ($parsed === null) {
                    $statusError = 'Die Statusantwort des Servers war kein gültiges JSON.';
                } else {
                    $decisions = $parsed;
                    $alertsExitCode = null;
                    $alertsResult = runRescueCommand('ALERTS', $clientIp, $host, $port, $user, $key, $alertsExitCode);
                    if ($alertsExitCode === 0) {
                        $parsedAlerts = jsonList($alertsResult, 'alerts');
                        if ($parsedAlerts === null) $alertsWarning = 'Alert-Details waren nicht lesbar.';
                        else $alerts = $parsedAlerts;
                    } else {
                        $alertsWarning = 'Alert-Details konnten nicht geladen werden.';
                    }
                }
            }
        }
    }
}

$checkedAt = date('d.m.Y H:i:s T');
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars($pageTitle . ' – ' . $serverName, ENT_QUOTES, 'UTF-8') ?></title>
<style>
body{font-family:Arial,sans-serif;max-width:800px;margin:50px auto;padding:0 18px;line-height:1.5;color:#202124}.ip,.details{background:#f5f5f5;padding:15px;overflow:auto;border-radius:6px}.actions{display:flex;gap:12px;flex-wrap:wrap;margin:22px 0}button{font-size:17px;padding:11px 20px;cursor:pointer;border-radius:6px;border:1px solid #777;background:#fff}button.primary{color:#fff;background:#b42318;border-color:#b42318}button.danger{color:#fff;background:#7a271a;border-color:#7a271a}.box{padding:16px;margin-top:20px;border:1px solid;border-radius:6px;overflow:hidden}.ok{background:#ecfdf3;border-color:#28a745}.warn{background:#fff8e1;border-color:#d49b00}.error{background:#fef3f2;border-color:#dc3545}table{border-collapse:collapse;width:100%;table-layout:fixed;margin:12px 0 22px}th,td{text-align:left;vertical-align:top;padding:8px;border-bottom:1px solid #ccc;overflow-wrap:anywhere;word-break:break-word}th{width:32%}input[type=text]{font-size:17px;padding:10px;width:min(320px,90%)}.muted{color:#666;font-size:14px}.source-grid{display:grid;grid-template-columns:minmax(90px,120px) 1fr;gap:4px 12px}.source-grid strong{white-space:nowrap}
</style>
</head>
<body>
<h1>🛡️ <?= htmlspecialchars($pageTitle, ENT_QUOTES, 'UTF-8') ?></h1>
<p><strong>Server:</strong> <?= htmlspecialchars($serverName, ENT_QUOTES, 'UTF-8') ?><?php if ($serverDescription !== ''): ?> · <?= htmlspecialchars($serverDescription, ENT_QUOTES, 'UTF-8') ?><?php endif; ?></p>
<p><strong>Deine erkannte IP:</strong></p>
<div class="ip"><?= htmlspecialchars($clientIp ?: 'unbekannt', ENT_QUOTES, 'UTF-8') ?></div>

<?php if ($requestError !== null): ?><div class="box error"><strong>❌ <?= htmlspecialchars($requestError, ENT_QUOTES, 'UTF-8') ?></strong></div><?php endif; ?>
<?php if (!$validIp): ?><div class="box error"><strong>Die Besucher-IP konnte nicht sicher erkannt werden.</strong></div><?php else: ?>
<form method="post" class="actions">
    <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($_SESSION['csrf_token'], ENT_QUOTES, 'UTF-8') ?>">
    <button type="submit" name="action" value="status">Status prüfen</button>
    <button type="submit" name="action" value="unban" class="primary">Meine IP entsperren</button>
    <?php if ($isAdmin): ?><button type="submit" name="action" value="confirm_all" class="danger">Alle Sperren löschen</button><?php endif; ?>
</form>
<?php endif; ?>

<?php if ($showDeleteAllConfirmation): ?>
<div class="box error">
    <strong>⚠️ Wirklich alle CrowdSec-Sperren löschen?</strong>
    <p>Das betrifft sämtliche IPv4- und IPv6-Adressen. Gib zur Bestätigung exakt <strong>ALLE LÖSCHEN</strong> ein.</p>
    <form method="post">
        <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($_SESSION['csrf_token'], ENT_QUOTES, 'UTF-8') ?>">
        <input type="text" name="confirmation" autocomplete="off" required>
        <button type="submit" name="action" value="unban_all" class="danger">Endgültig alle löschen</button>
    </form>
</div>
<?php endif; ?>

<?php if ($action === 'status' && $result !== null): ?>
<?php if ($exitCode !== 0 || $statusError !== null): ?>
<div class="box error"><strong>❌ Status konnte nicht ermittelt werden.</strong><pre class="details"><?= htmlspecialchars($statusError ?? $result, ENT_QUOTES, 'UTF-8') ?></pre></div>
<?php elseif ($decisions === []): ?>
<div class="box ok"><strong>✅ Nicht gesperrt</strong><br>Für diese IP liegt aktuell keine aktive CrowdSec-Entscheidung vor.<p class="muted">Geprüft: <?= htmlspecialchars($checkedAt, ENT_QUOTES, 'UTF-8') ?></p></div>
<?php else: ?>
<div class="box warn"><strong>⛔ Gesperrt – <?= count($decisions) ?> aktive Entscheidung(en)</strong>
<?php foreach ($decisions as $decision): if (!is_array($decision)) continue; ?>
<table>
<tr><th>Warum gesperrt?</th><td><?= htmlspecialchars(field($decision, ['scenario', 'reason']), ENT_QUOTES, 'UTF-8') ?></td></tr>
<tr><th>IP oder Bereich</th><td><?= htmlspecialchars(field($decision, ['value']), ENT_QUOTES, 'UTF-8') ?> (<?= htmlspecialchars(field($decision, ['scope']), ENT_QUOTES, 'UTF-8') ?>)</td></tr>
<tr><th>Maßnahme</th><td><?= htmlspecialchars(field($decision, ['type', 'action']), ENT_QUOTES, 'UTF-8') ?></td></tr>
<tr><th>Herkunft</th><td><?= htmlspecialchars(field($decision, ['origin']), ENT_QUOTES, 'UTF-8') ?></td></tr>
<tr><th>Verbleibend/Ablauf</th><td><?= htmlspecialchars(field($decision, ['until', 'expiration', 'duration']), ENT_QUOTES, 'UTF-8') ?></td></tr>
</table>
<?php endforeach; ?><p class="muted">Geprüft: <?= htmlspecialchars($checkedAt, ENT_QUOTES, 'UTF-8') ?></p></div>
<?php endif; ?>

<?php if ($alertsWarning !== null): ?><div class="box warn"><?= htmlspecialchars($alertsWarning, ENT_QUOTES, 'UTF-8') ?></div><?php endif; ?>
<?php if ($alerts !== []): ?>
<div class="box"><strong>Letzte zugehörige CrowdSec-Alerts</strong>
<?php foreach (array_slice($alerts, 0, 5) as $alert): if (!is_array($alert)) continue; ?>
<table>
<tr><th>Szenario</th><td><?= htmlspecialchars(field($alert, ['scenario']), ENT_QUOTES, 'UTF-8') ?></td></tr>
<tr><th>Zeitpunkt</th><td><?= htmlspecialchars(field($alert, ['created_at', 'start_at']), ENT_QUOTES, 'UTF-8') ?></td></tr>
<tr><th>Ereignisse</th><td><?= htmlspecialchars(field($alert, ['events_count']), ENT_QUOTES, 'UTF-8') ?></td></tr>
<tr><th>Quelle</th><td><div class="source-grid"><?php foreach (sourceDetails($alert) as $label => $sourceValue): ?><strong><?= htmlspecialchars($label, ENT_QUOTES, 'UTF-8') ?>:</strong><span><?= htmlspecialchars($sourceValue, ENT_QUOTES, 'UTF-8') ?></span><?php endforeach; ?></div></td></tr>
</table>
<?php endforeach; ?></div>
<?php endif; ?>
<?php endif; ?>

<?php if ($action === 'unban' && $result !== null): ?>
<div class="box <?= $exitCode === 0 ? 'ok' : 'error' ?>"><strong><?= $exitCode === 0 ? '✅ IP erfolgreich entsperrt.' : '❌ Fehler beim Entsperren' ?></strong><?php if (trim($result) !== ''): ?><pre class="details"><?= htmlspecialchars($result, ENT_QUOTES, 'UTF-8') ?></pre><?php endif; ?></div>
<?php endif; ?>

<?php if ($action === 'unban_all' && $result !== null): ?>
<div class="box <?= $exitCode === 0 ? 'ok' : 'error' ?>"><strong><?= $exitCode === 0 ? '✅ Alle CrowdSec-Sperren wurden gelöscht.' : '❌ Fehler beim Löschen aller Sperren' ?></strong><?php if (trim($result) !== ''): ?><pre class="details"><?= htmlspecialchars($result, ENT_QUOTES, 'UTF-8') ?></pre><?php endif; ?></div>
<?php endif; ?>
<?php if ($isAdmin): ?><p class="muted"><a href="admin.php">Benutzerverwaltung öffnen</a></p><?php endif; ?>
</body>
</html>
