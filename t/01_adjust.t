use v5.42;
use Test::More 0.98;
use HTTP::Server::Upload;

{
  my $server = HTTP::Server::Upload->new(store_dir => '/tmp/whatever/');
  is(
    $server->store_dir => '/tmp/whatever',
    'ADJUST block fixed store_dir (Unix-style path)'
  );
}

{
  my $backslash = '\\';
  is(
    length $backslash => 1,
    'Backslash is length 1'
  );

  my $server = HTTP::Server::Upload->new(store_dir => 'C:\windows\temp\whatever'.$backslash);
  is(
    $server->store_dir => 'C:\windows\temp\whatever',
    'ADJUST block fixed store_dir (Windows-style path)'
  );
}

done_testing;
