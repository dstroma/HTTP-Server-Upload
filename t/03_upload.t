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
    if check_port $port;

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

done_testing();

# TODO
# - Check authorization, id/placeholder, security limits, do load testing
# - Look into using Test::TCP?

###############################################################################
# Make sure children are stopped

END { eval { kill 9, $_ } for @children }

###############################################################################
# Subs

sub test_upload(%params) {
  my $comment = delete $params{'comment'};

  # Setup directories
  my $dir = tempdir(CLEANUP => 1);
  my ($log_fh, $log_filename) = tempfile();

  DEBUG && say "Temp dir: $dir";
  DEBUG && say "Log file: $log_filename";

  # Start a test server
  my %std_params = (store_dir => $dir, log_file => $log_filename);
  my $child_pid = fork;
  if ($child_pid == 0) {
    my $server = HTTP::Server::Upload->new(%std_params, %params);
    $server->start;
    exit;
  }
  push @children, $child_pid;

  # Upload file and Test completion
  ok(
    upload(%std_params, %params),
    "Upload OK ($comment)"
  );

  # Terminate server
  kill 9, $child_pid;

  # Debug sleep
  DEBUG && say "Debug break, press enter:";
  DEBUG && <STDIN>;
}

sub upload (%params) {
  my $store_dir  = $params{'store_dir'};
  my $use_subdir = $params{'use_subdir'};
  my $host       = $params{'host'}   // "localhost";
  my $listen     = $params{'listen'} // 6896;
  my $size       = $params{'size'}   // 1024*16;
  my $upload_id  = $params{'upload_id'} // time() . int(rand(1000));

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
  print $sock "Connection: close\r\n";
  print $sock "\r\n";

  # Stream file body in chunks
  while (my $line = <$DATA>) {
    print $sock $line;
    #select undef, undef, undef, 0.01;
  }
  close $DATA;

  DEBUG && say "Sent data.\n";
  DEBUG && print "Server said: $_" for <$sock>;
  DEBUG && print "\n\n";
  close $sock;
  sleep 2;

  # Compare saved data to original
  my $orig_file = './t/upload.txt';
  my $dest_file = $use_subdir ?
                  "$store_dir/$upload_id/upload.body" :
                  "$store_dir/upload-$upload_id.body";

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
