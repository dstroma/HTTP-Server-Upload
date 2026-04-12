use v5.42;
use Test::More 0.98;
use File::Temp qw(tempfile tempdir);
use Fcntl qw(:seek);
use Net::EmptyPort qw(empty_port check_port);
use HTTP::Server::Upload;
use constant DEBUG => false;

our @children;
our $default_port = HTTP::Server::Upload->DEFAULT_PORT;

# Test with default port, skip if in use
SKIP:
{
  my $port = $default_port;

  skip "Port $port not available, cannot test default port", 1
    if check_port $port; # check_port returns true if port is in use

  test_upload(use_subdir =>  true, comment => "Default port $port");
}

# Test with custom port
{
  my $port1 = empty_port($default_port + 1); # specify lower bound
  test_upload(use_subdir => true,  listen => $port1, comment => "Custom port $port1 (use_subdir=true)");

  my $port2 = empty_port($default_port + 2); # specify lower bound
  test_upload(use_subdir => false, listen => $port2, comment => "Custom port $port2 (use_subdir=false)");
}

# Test unix domain socket
SKIP:
{
  skip "IO::Socket::UNIX not available, will not test listening on unix domain socket", 1
    unless eval { require IO::Socket::UNIX; 1 };

  my ($socket_fh, $socket_file) = tempfile();
  test_upload(use_subdir => true, listen => $socket_file, comment => "Listen on unix domain socket");
}

# Test with no id, let server auto-assign
{
  my $port = empty_port($default_port);
  test_upload(
    use_subdir  => true,
    listen      => $port,
    client      => { upload_id => undef },
    comment     => "Auto-assign upload id",
  );
}

# Test with ID required (do not give ID)
{
  my $port = empty_port($default_port);
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { require_id => true },
    client      => { upload_id => undef },
    comment     => "ID required -> should fail without one",
    should_fail => true,
  );
}

# Test with ID required (give ID)
{
  my $port = empty_port($default_port);
  my $upload_id = "upid-abc000_$$";
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { require_id => true },
    client      => { upload_id => $upload_id },
    comment     => "Client-supplied ID"
  );
}

# Test with placeholder
{
  # Give id and have placeholder ready
  my $port = empty_port($default_port);
  my $upload_id = "upid-def111_$$";
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { require_id => true, require_placeholder => true },
    client      => { upload_id => $upload_id },
    comment     => "Client-supplied ID, placeholder required",
    make_placeholder => true,
  );
}

# Authorization Tests #

# Test with placeholder without making one, should fail
{
  my $port = empty_port($default_port);
  my $upload_id = "upid-ghi222_$$";
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { require_id => true, require_placeholder => true },
    client      => { upload_id => $upload_id },
    comment     => "No ID, placeholder required -> should fail",
    make_placeholder => false,
    should_fail => true,
  );
}

# Test authorization
{
  my $port = empty_port($default_port);
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { auth_required => true, auth_file => 't/auth.txt' },
    comment     => "Auth required -> no token should fail",
    should_fail => true,
  );
}

foreach my $wrong_token ('Bearer 123_45', 'Bearer abc_defg', 'Beerer abc_def', 'Adhoc Token') {
  my $port = empty_port($default_port);
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { auth_required => true, auth_file => 't/auth.txt' },
    client      => { authorization => $wrong_token },
    comment     => "Auth required -> wrong token '$wrong_token' should fail",
    should_fail => true,
  );
}

foreach my $right_token ('Bearer 123_456', 'Bearer abc_def', 'Adhoc Token Style 1', 'Adhoc Token Style 2') {
  my $port = empty_port($default_port);
  test_upload(
    use_subdir  => true,
    listen      => $port,
    server      => { auth_required => true, auth_file => 't/auth.txt' },
    client      => { authorization => $right_token },
    comment     => "Auth with correct token '$right_token'",
  );
}

done_testing();

# TODO
# - Check security limits, do load testing
# - Look into using Test::TCP?

###############################################################################
# Make sure children are stopped

END { eval { kill 9, $_ } for @children }

###############################################################################
# Subs

sub test_upload(%params) {
  state $cnt = 0;
  $cnt++;
  DEBUG && say "Test $cnt starting...";

  my $comment     = delete $params{'comment'};
  my $should_fail = delete $params{'should_fail'};
  my $placehold   = delete $params{'make_placeholder'};
  my %extra_client_params = $params{'client'} ? (delete $params{'client'})->%* : ();
  my %extra_server_params = $params{'server'} ? (delete $params{'server'})->%* : ();

  # Setup directories
  my $dir = tempdir(CLEANUP => 1);
  my ($log_fh, $log_filename) = tempfile();

  DEBUG && say "Temp dir: $dir";
  DEBUG && say "Log file: $log_filename";

  # Start a test server
  my %std_params = (store_dir => $dir, log_file => $log_filename);
  my $child_pid = fork;
  if ($child_pid == 0) {
    my $server = HTTP::Server::Upload->new(%std_params, %params, %extra_server_params);
    $server->start;
    exit;
  }
  push @children, $child_pid;

  # Make placeholder for server?
  if ($placehold) {
    my $store_dir  = $dir;
    my $use_subdir = $params{'use_subdir'};
    my $upload_id  = $params{'upload_id'} || $extra_client_params{'upload_id'};
    die "Cannot determine store_dir"  unless defined $store_dir;
    die "Cannot determine use_subdir" unless defined $use_subdir;
    die "Cannot determine upload_id"  unless defined $upload_id;
    if ($use_subdir) {
      mkdir "$store_dir/$upload_id/";
    } else {
      open my $fh, '>', "$store_dir/upload-$upload_id.ready";
      print $fh, 'Ready';
      close $fh;
    }
  }

  # Upload file and Test completion
  ok(
    (upload(%std_params, %params, %extra_client_params) xor $should_fail),
    "Upload test ($comment)"
  );

  # Terminate server
  kill 9, $child_pid;

  # Debug sleep
  DEBUG && say "...test $cnt done.\n\n";
  DEBUG && say "Debug sleep (15 seconds)";
  DEBUG && sleep 15;
}

sub upload (%params) {
  my $store_dir  = $params{'store_dir'};
  my $use_subdir = $params{'use_subdir'};
  my $host       = $params{'host'}   // "localhost";
  my $listen     = $params{'listen'} // 6896;
  my $size       = $params{'size'}   // 1024*16;
  my $upload_id  = $params{'upload_id'} // time() . int(rand(1000));
  my $placehold  = $params{'make_placeholder'};

  # Override upload_id?
  $upload_id = '' if exists $params{'upload_id'} and not defined $params{'upload_id'};

  my ($port, $udsfile);
  if ($listen =~ m/^\d+$/) {
    $port    = $listen;
  } else {
    $udsfile = $listen;
  }

  # Connect to server
  sleep 2;
  my $sock;
  if ($port) {
    require IO::Socket::INET;
    $sock = IO::Socket::INET->new(
      PeerHost => $host,
      PeerPort => $port,
      Proto    => 'tcp'
    ) or die "Client can't connect to server: $IO::Socket::errstr. $!";
  } elsif ($udsfile) {
    require IO::Socket::UNIX;
    $sock = IO::Socket::UNIX->new(
      Type  => IO::Socket::SOCK_STREAM,
      Peer  => $udsfile,
    ) or die "Client cannot connect to server: $IO::Socket::errstr. $!";
  } else {
    die 'Listen is not a port or unix domain socket!';
  }

  # Read DATA size
  open(my $DATA, '<', './t/upload.txt') or die "Cannot open t/upload.txt: $!";
  my $buf  = '';
  my $data_size = 0;
  $data_size++ while read($DATA, $buf, 1);
  seek $DATA, 0, SEEK_SET;

  # Read boundary
  my $boundary = <$DATA>;
  chomp $boundary;
  seek $DATA, 0, SEEK_SET;

  # Send request headers
  print $sock "POST /upload/$upload_id HTTP/1.0\r\n";
  print $sock "Host: $host\r\n";
  print $sock "Content-Length: $data_size\r\n";
  print $sock "Content-Type: multipart/form-data; boundary=$boundary\r\n";
  print $sock "Authorization: $params{'authorization'}\r\n"
    if exists $params{'authorization'};
  print $sock "Connection: close\r\n";
  print $sock "\r\n";

  my @response;

  # Check for early server response
  my $select = IO::Select->new($sock);
  if ($select->can_read(1)) {
    push @response, $_ while <$sock>;
  }
  return undef if @response and $response[0] !~ m/200\s+OK/;

  # Stream file body in chunks
  while (my $line = <$DATA>) {
    print $sock $line;
    #select undef, undef, undef, 0.01;
  }
  close $DATA;

  # Read response
  push @response, $_ while <$sock>;

  DEBUG && say "Sent data.\n";
  DEBUG && print "Server said: $_" for @response;
  DEBUG && print "\n\n";
  close $sock;
  sleep 2;

  return undef unless $response[0] =~ m/200\s+OK/;

  # If we let the server assign the upload_id, we have to figure it out
  if ($upload_id eq '') {
    my @items;
    opendir(my $DH, $store_dir) or die "Can't open directory: $!";
    while (my $item = readdir($DH)) {
      push @items, $item if $item ne '.' and $item ne '..';
    }
    closedir($DH);

    if ($use_subdir) {
      if (@items > 1) {
        warn "Unexpected files in temporary directory\n";
        say $_ for @items;
        say "Press enter"; <STDIN>;
        die;
      }
      $upload_id = shift @items;
    } else {
      my $bodies = 0;
      foreach my $item (@items) {
        if ($item =~ m/^(.+)\.body$/) {
          $upload_id = $1;
          $bodies++;
        }
      }
      die "Cannot determine upload id" unless $upload_id and length $upload_id;
      die "More than one body" if $bodies > 1;
    }
    DEBUG && say "Discovered upload_id: $upload_id";
  }

  # Compare saved data to original
  my $orig_file = './t/upload.txt';
  my $dest_file = $use_subdir ?
                  "$store_dir/$upload_id/upload.body" :
                  "$store_dir/upload-$upload_id.body";

  DEBUG && say "Original file: $orig_file";
  DEBUG && say "Uploaded file: $dest_file";

  require Digest::MD5;
  open(my $fh1, '<', $orig_file) or die "Test cannot open original file    '$orig_file': $!";
  open(my $fh2, '<', $dest_file) or die "Test cannot open destination file '$dest_file': $!";

  my $dig1 = Digest::MD5->new;
  my $dig2 = Digest::MD5->new;

  $dig1->addfile($fh1) if $fh1;
  $dig2->addfile($fh2) if $fh2;

  close $fh1;
  close $fh2;

  return ($dig1->digest eq $dig2->digest);
}
