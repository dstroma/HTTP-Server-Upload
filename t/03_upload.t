use v5.42;
use Test::More 0.98;
use File::Temp qw/tempfile tempdir/;
use Fcntl qw(:seek);
use HTTP::Server::Upload;
use constant DEBUG => false;

my $dir = tempdir(CLEANUP => 1);
my ($log_fh, $log_filename) = tempfile();

DEBUG && say "Temp dir: $dir";
DEBUG && say "Log file: $log_filename";

# Start a test server
my $child_pid = fork;
if ($child_pid == 0) {
  my $server = HTTP::Server::Upload->new(use_subdir => true, store_dir => $dir, log_file => $log_filename);
  $server->start;
  exit;
}

# Do tests
upload();

# Terminate server
kill 9, $child_pid;

# Debug sleep
DEBUG && say "Debug sleep...";
DEBUG && sleep 60;

# Done
done_testing();

###############################################################################

sub upload (%params) {
  require IO::Socket::INET;
  my $host      = $params{'host'} // "localhost";
  my $port      = $params{'port'} // 6896;
  my $size      = $params{'size'} // 1024*16;
  my $upload_id = $params{'upload_id'} // time() . int(rand(1000));

  # Connect to server
  sleep 2;
  my $sock = IO::Socket::INET->new(
    PeerHost => $host,
    PeerPort => $port,
    Proto    => 'tcp'
  ) or die "Client can't connect to server: $!";

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
  use Digest::MD5;
  open(my $fh1, '<', "./t/upload.txt"             ) or die "Cannot open file: $!";
  open(my $fh2, '<', "$dir/$upload_id/upload.body") or die "Cannot open file: $!";

  my $dig1 = Digest::MD5->new;
  my $dig2 = Digest::MD5->new;

  $dig1->addfile($fh1);
  $dig2->addfile($fh2);

  is($dig1->digest => $dig2->digest, "Uploaded file matches original");

  close $fh1;
  close $fh2;
}
