<?php
// smoke.php — PHP definition smoke.

function smokeFn(): string {
    return "smoke";
}

class SmokePhp {
    public function go(): string {
        return smokeFn();
    }
}
