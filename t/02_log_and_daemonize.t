use v5.40;
use Test::More 0.98;
use File::Temp qw(tempfile);
use HTTP::Server::Upload;

foreach my $daemonize (false, true) {
  my ($temp_fh, $filename) = tempfile();

  my $child_pid = fork();
  die "Unable to fork!" unless defined $child_pid;

  if ($child_pid == 0) {
    my $server = HTTP::Server::Upload->new(log_file => $filename, daemonize => $daemonize);
    $server->start;
    exit;
  }
  say "Forked PID: $child_pid";

  sleep 1;

  # Check log
  open my $fh, '<', $filename or die "Cannot open $filename for reading, $!";
  my $server_log_pid;
  foreach my $line (<$fh>) {
     ($server_log_pid) = $line =~ m/PID\s(\d+)\sstarting/;
     last if $server_log_pid;
  }
  close $fh;

  # Server PID in log file?
  ok($server_log_pid, "Server logged PID");

  # Server PID matches expected?
  is(  $server_log_pid => $child_pid, "Server PID $server_log_pid is correct") if !$daemonize;
  isnt($server_log_pid => $child_pid, "Server PID $server_log_pid is correct") if $daemonize;

  # Check if pid is running
  ok(kill(0, $server_log_pid), "Server is running with PID $server_log_pid");

  sleep 1;

  # Kill child
  ok(kill(9, $server_log_pid), "Terminate server");
}

done_testing();
