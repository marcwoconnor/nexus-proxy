<?php
require_once($_SERVER['DOCUMENT_ROOT'].'/config/security_headers.php');
setSecurityHeaders();

// Load language support
require_once('../config/language.php');
// Load Pi-Star release info
$pistarReleaseConfig = '/etc/pistar-release';
$configPistarRelease = array();
if (file_exists($pistarReleaseConfig)) {
    $configPistarRelease = parse_ini_file($pistarReleaseConfig, true);
}
require_once('../config/version.php');

$configFile = '/etc/nexus-proxy.json';
$statusMsg = '';
$statusClass = '';

// Check if nexus-proxy is installed
$installed = file_exists('/usr/local/bin/nexus-proxy');
$running = false;
if ($installed) {
    exec('systemctl is-active nexus-proxy 2>/dev/null', $output, $ret);
    $running = ($ret === 0);
}

// Load current config
$config = array(
    'repeater_id' => '',
    'passphrase' => '',
    'discovery' => 'nexus.techsnet.net',
    'log_level' => 'info'
);

if (file_exists($configFile)) {
    $json = json_decode(file_get_contents($configFile), true);
    if ($json) {
        if (isset($json['local']['repeater_id'])) $config['repeater_id'] = $json['local']['repeater_id'];
        if (isset($json['cluster']['passphrase'])) $config['passphrase'] = $json['cluster']['passphrase'];
        if (isset($json['cluster']['discovery'])) $config['discovery'] = $json['cluster']['discovery'];
        if (isset($json['log_level'])) $config['log_level'] = $json['log_level'];
    }
}

// Handle form submission
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
    if ($_POST['action'] === 'save') {
        $newConfig = array(
            'local' => array(
                'address' => '127.0.0.1',
                'port' => 62031,
                'passphrase' => 'passw0rd',
                'repeater_id' => intval($_POST['repeater_id'])
            ),
            'cluster' => array(
                'discovery' => trim($_POST['discovery']),
                'passphrase' => trim($_POST['passphrase']),
                'ping_interval' => 5,
                'ping_timeout' => 3,
                'discovery_interval' => 30
            ),
            'subscription' => array(
                'slot1' => null,
                'slot2' => null
            ),
            'log_level' => $_POST['log_level']
        );

        // Write config via temp file (Pi-Star filesystem is read-only, use sudo)
        $tmpFile = '/tmp/nexus-proxy-config.json';
        file_put_contents($tmpFile, json_encode($newConfig, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
        exec("sudo cp $tmpFile $configFile && sudo chmod 640 $configFile", $out, $ret);
        unlink($tmpFile);

        if ($ret === 0) {
            $statusMsg = 'Configuration saved.';
            $statusClass = 'success';
            $config['repeater_id'] = $newConfig['local']['repeater_id'];
            $config['passphrase'] = $newConfig['cluster']['passphrase'];
            $config['discovery'] = $newConfig['cluster']['discovery'];
            $config['log_level'] = $newConfig['log_level'];

            // Restart service if running
            if ($running) {
                exec('sudo systemctl restart nexus-proxy 2>/dev/null');
                $statusMsg .= ' Service restarted.';
            }
        } else {
            $statusMsg = 'Error saving configuration.';
            $statusClass = 'error';
        }
    } elseif ($_POST['action'] === 'start') {
        exec('sudo systemctl start nexus-proxy 2>/dev/null', $out, $ret);
        $running = ($ret === 0);
        $statusMsg = $running ? 'Service started.' : 'Failed to start service.';
        $statusClass = $running ? 'success' : 'error';
    } elseif ($_POST['action'] === 'stop') {
        exec('sudo systemctl stop nexus-proxy 2>/dev/null');
        $running = false;
        $statusMsg = 'Service stopped.';
        $statusClass = 'success';
    } elseif ($_POST['action'] === 'restart') {
        exec('sudo systemctl restart nexus-proxy 2>/dev/null', $out, $ret);
        $running = ($ret === 0);
        $statusMsg = $running ? 'Service restarted.' : 'Failed to restart service.';
        $statusClass = $running ? 'success' : 'error';
    }
}

// Get recent logs
$logs = '';
if ($installed) {
    exec('journalctl -u nexus-proxy -n 15 --no-pager 2>/dev/null', $logLines);
    $logs = implode("\n", $logLines);
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Pi-Star - DMR Nexus Configuration</title>
    <link rel="stylesheet" type="text/css" href="../css/pistar-css.php" />
    <link rel="stylesheet" type="text/css" href="../css/nexus-theme.css?version=1.0" />
    <link rel="shortcut icon" href="images/favicon.ico" type="image/x-icon" />
    <style>
        .nexus-form { max-width: 600px; margin: 0 auto; }
        .nexus-form label { display: block; margin: 12px 0 4px; font-weight: bold; }
        .nexus-form input[type="text"],
        .nexus-form input[type="number"],
        .nexus-form input[type="password"],
        .nexus-form select {
            width: 100%; padding: 8px; box-sizing: border-box;
            border: 1px solid #334155; border-radius: 4px;
            background: #0f172a; color: #e2e8f0;
        }
        .nexus-form input:focus, .nexus-form select:focus {
            border-color: #0ea5e9; outline: none;
            box-shadow: 0 0 0 2px rgba(14,165,233,0.3);
        }
        .nexus-status { display: inline-block; padding: 4px 12px; border-radius: 12px; font-size: 0.85em; font-weight: bold; }
        .nexus-status.running { background: #065f46; color: #6ee7b7; }
        .nexus-status.stopped { background: #7f1d1d; color: #fca5a5; }
        .nexus-status.not-installed { background: #78350f; color: #fde68a; }
        .btn-row { margin: 20px 0; display: flex; gap: 8px; flex-wrap: wrap; }
        .btn-row button { padding: 8px 20px; border: none; border-radius: 4px; cursor: pointer; font-weight: bold; }
        .btn-save { background: #0ea5e9; color: white; }
        .btn-start { background: #059669; color: white; }
        .btn-stop { background: #dc2626; color: white; }
        .btn-restart { background: #d97706; color: white; }
        .btn-row button:hover { opacity: 0.9; }
        .msg-success { background: #065f46; color: #6ee7b7; padding: 10px; border-radius: 4px; margin: 10px 0; }
        .msg-error { background: #7f1d1d; color: #fca5a5; padding: 10px; border-radius: 4px; margin: 10px 0; }
        .log-box { background: #020617; color: #4ade80; padding: 12px; border-radius: 4px;
                   font-family: monospace; font-size: 0.8em; white-space: pre-wrap;
                   max-height: 300px; overflow-y: auto; margin-top: 10px; }
        .help-text { font-size: 0.85em; color: #94a3b8; margin-top: 2px; }
    </style>
</head>
<body>
<div class="container">
<?php include './header-menu.inc'; ?>
<div class="contentwide">

<h2>DMR Nexus — Cluster-Aware Hotspot</h2>

<div style="margin: 15px 0;">
    Status:
    <?php if (!$installed): ?>
        <span class="nexus-status not-installed">Not Installed</span>
        <p>Install the Nexus proxy by running on your Pi-Star terminal:</p>
        <code>curl -sL https://dmrnexus.net/install.sh | sudo bash</code>
    <?php elseif ($running): ?>
        <span class="nexus-status running">Running</span>
    <?php else: ?>
        <span class="nexus-status stopped">Stopped</span>
    <?php endif; ?>
</div>

<?php if ($statusMsg): ?>
    <div class="msg-<?php echo $statusClass; ?>"><?php echo htmlspecialchars($statusMsg); ?></div>
<?php endif; ?>

<?php if ($installed): ?>

<form method="post" class="nexus-form">
    <input type="hidden" name="action" value="save" />

    <label for="repeater_id">DMR Radio ID</label>
    <input type="number" name="repeater_id" id="repeater_id"
           value="<?php echo htmlspecialchars($config['repeater_id']); ?>"
           placeholder="e.g. 3121234" required />
    <div class="help-text">Your DMR ID from RadioID.net</div>

    <label for="passphrase">Network Passphrase</label>
    <input type="password" name="passphrase" id="passphrase"
           value="<?php echo htmlspecialchars($config['passphrase']); ?>"
           placeholder="From your DMR Nexus admin" required />
    <div class="help-text">Provided by your DMR Nexus network administrator</div>

    <label for="discovery">Discovery Domain</label>
    <input type="text" name="discovery" id="discovery"
           value="<?php echo htmlspecialchars($config['discovery']); ?>"
           placeholder="dmrnexus.net" />
    <div class="help-text">DNS SRV domain for automatic server discovery. Leave as default unless directed otherwise.</div>

    <label for="log_level">Log Level</label>
    <select name="log_level" id="log_level">
        <option value="info" <?php if ($config['log_level'] === 'info') echo 'selected'; ?>>Info</option>
        <option value="debug" <?php if ($config['log_level'] === 'debug') echo 'selected'; ?>>Debug</option>
        <option value="warn" <?php if ($config['log_level'] === 'warn') echo 'selected'; ?>>Warning</option>
        <option value="error" <?php if ($config['log_level'] === 'error') echo 'selected'; ?>>Error</option>
    </select>

    <div class="btn-row">
        <button type="submit" class="btn-save">Save &amp; Apply</button>
    </div>
</form>

<h3>Service Control</h3>
<div class="btn-row">
    <form method="post" style="display:inline"><input type="hidden" name="action" value="start" /><button type="submit" class="btn-start">Start</button></form>
    <form method="post" style="display:inline"><input type="hidden" name="action" value="stop" /><button type="submit" class="btn-stop">Stop</button></form>
    <form method="post" style="display:inline"><input type="hidden" name="action" value="restart" /><button type="submit" class="btn-restart">Restart</button></form>
</div>

<h3>Recent Logs</h3>
<div class="log-box"><?php echo htmlspecialchars($logs ?: 'No logs available.'); ?></div>

<?php endif; ?>

</div>
</div>
</body>
</html>
