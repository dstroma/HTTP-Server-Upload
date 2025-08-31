requires perl => 'v5.42';

requires 'HTTP::Status' => '6.00';

on test => sub {
    requires 'Test::More' => '0.98';
};

