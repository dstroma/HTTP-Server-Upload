#!perl
use v5.42;
use HTTP::Server::Upload;

my $parse_argv = sub {
  my $maybe_params = join('|', qw(
    listen listen_queue max_clients auth_required auth_file store_dir

    require_id require_placeholder overwrite use_subdir

    select_timeout_busy select_timeout_idle

    read_timeout_head read_timeout_body write_timeout

    max_header_size max_body_size
  ));

  my %args;
  {
    my @args;
    my $prev_el;
    foreach my $i (0..$#ARGV) {
      my $el = $ARGV[$i];
      if ($el =~ m/^--/) {
        push @args, $el;
      } elsif ($el =~ m/^-[\w\d]/) {
        die "Short option $el not supported\n";
      } else {
        $args[$i-1] .= " $el";
      }
    }

    foreach my $arg (@args) {
      if ($arg =~ m/^--($maybe_params)(?:[\s=]*(.+))?$/) {
        my $key = $1;
        my $val = $2 // true;
        $args{$key} = $val;
      } else {
        die "Invalid argument: $arg\n";
      }
    }
  }
  return \%args;
};

my $server;
{
  my $args = $parse_argv->();
  undef $parse_argv;
  $server = HTTP::Server::Upload->new(%$args);
}

$server->start;
