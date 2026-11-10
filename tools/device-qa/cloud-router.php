<?php

// Only used by the explicit local device QA runner. No production DB or token.
$cloud = getenv('MONITOR_QA_CLOUD_ROOT');
$stateDir = getenv('MONITOR_QA_STATE');
if (! $cloud || ! $stateDir || getenv('DB_CONNECTION') !== 'sqlite'
    || getenv('DB_DATABASE') !== $stateDir.'/cloud.sqlite') {
    throw new RuntimeException('isolated SQLite QA environment required');
}
require $cloud.'/vendor/autoload.php';
$app = require $cloud.'/bootstrap/app.php';
$app->instance('request', Illuminate\Http\Request::capture());
$kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);
$kernel->bootstrap();
Illuminate\Support\Facades\Http::preventStrayRequests();
Illuminate\Support\Facades\Queue::fake();
Illuminate\Support\Facades\Mail::fake();

if (PHP_SAPI === 'cli' && ($argv[1] ?? '') === 'seed') {
    Illuminate\Support\Facades\Artisan::call('migrate', ['--force' => true]);
    $user = App\Models\User::factory()->create(['email' => 'monitor-deviceqa@example.test']);
    $project = App\Models\Project::create(['owner_id' => $user->id, 'name' => 'Monitor Device QA', 'slug' => 'monitor-deviceqa']);
    foreach (['A', 'B'] as $variant) {
        $token = 'moo_deviceqa_only_20261110_token_'.$variant;
        $project->tokens()->create(['name' => 'local fixture '.$variant, 'token_hash' => hash('sha256', $token),
            'prefix' => substr($token, 0, 12), 'abilities' => ['app_errors']]);
    }
    echo "isolated cloud database seeded\n";
    exit;
}

if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/qa/summary') {
    header('Content-Type: application/json');
    echo json_encode(['rows' => App\Models\AppError::count(), 'count' => App\Models\AppError::sum('count'),
        'records' => App\Models\AppError::all(['kind', 'err_name', 'count', 'last_seen', 'payload', 'severity'])->toArray()]);
    exit;
}

$body = file_get_contents('php://input');
$payload = json_decode($body, true);
$records = is_array($payload['records'] ?? null) ? $payload['records'] : [];
$state = json_decode(file_get_contents($stateDir.'/control.json'), true);
$mode = $state['mode'] ?? 'accept';
file_put_contents($stateDir.'/requests.jsonl', json_encode(['at' => microtime(true), 'mode' => $mode,
    'bytes' => strlen($body), 'records' => $records], JSON_UNESCAPED_UNICODE)."\n", FILE_APPEND | LOCK_EX);
header('Content-Type: application/json');
if ($mode === 'hold' || $mode === 'unauthorized') {
    http_response_code($mode === 'hold' ? 503 : 401);
    echo '{"ok":false}';
    exit;
}
if ($mode === 'retry-after' && ($state['remaining'] ?? 0) > 0) {
    $state['remaining']--;
    file_put_contents($stateDir.'/control.json', json_encode($state));
    http_response_code(429);
    header('Retry-After: 3');
    echo '{"ok":false}';
    exit;
}
if ($mode === 'partial' && ($state['remaining'] ?? 0) > 0 && count($records) >= 2) {
    $state['remaining']--;
    file_put_contents($stateDir.'/control.json', json_encode($state));
    // Commit even indexes through the actual controller; withhold odd ones once.
    $indexes = array_values(array_filter(array_keys($records), fn ($i) => $i % 2 === 0));
    $payload['records'] = array_map(fn ($i) => $records[$i], $indexes);
    $request = Illuminate\Http\Request::create('/api/v1/app-errors/intake', 'POST', [], [], [], [
        'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json',
        'HTTP_X_PROJECT_TOKEN' => $_SERVER['HTTP_X_PROJECT_TOKEN'] ?? '',
    ], json_encode($payload));
    $response = $kernel->handle($request);
    $result = json_decode($response->getContent(), true);
    $receipts = [];
    foreach ($records as $i => $record) {
        if ($i % 2 === 0) {
            $receipt = $result['results'][array_search($i, $indexes)] ?? [];
            $receipt['index'] = $i;
        } else {
            $receipt = ['index' => $i, 'hash' => null, 'status' => 'skipped', 'retryable' => true, 'reason' => 'qa_transient'];
        }
        $receipts[] = $receipt;
    }
    $result['results'] = $receipts;
    $result['skipped'] = count($records) - count($indexes);
    http_response_code($response->getStatusCode());
    echo json_encode($result);
    $kernel->terminate($request, $response);
    exit;
}
$request = Illuminate\Http\Request::capture();
$response = $kernel->handle($request);
$response->send();
$kernel->terminate($request, $response);
