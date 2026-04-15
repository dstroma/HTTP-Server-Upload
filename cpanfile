requires perl => 'v5.40';

requires 'HTTP::Status' => '6.00';

on test => sub {
    requires 'Test::More' => '0.98';
    requires 'Net::EmptyPort';
};

