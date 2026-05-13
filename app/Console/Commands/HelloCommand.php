<?php

namespace App\Console\Commands;

use App\Jobs\HelloJob;
use Illuminate\Console\Command;

class HelloCommand extends Command
{
    protected $signature = 'hello:dispatch';

    protected $description = 'Dispatch the HelloJob';

    public function handle()
    {
        HelloJob::dispatch();
        $this->info('HelloJob dispatched.');
    }
}
