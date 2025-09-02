#!perl
use v5.42;
use HTTP::Server::Upload;

# We parse our own arguments
# Getopt::Long is 1500 lines!
my $parse_argv = sub {
  my @maybe_params = qw(
    listen listen_queue max_clients auth_required auth_file store_dir

    require_id require_placeholder overwrite use_subdir

    select_timeout_busy select_timeout_idle

    read_timeout_head read_timeout_body write_timeout

    max_header_size max_body_size

    help dump_args
  );

  my %args;
  {
    my @args;
    my $prev_el;
    foreach my $i (0..$#ARGV) {
      my $el = $ARGV[$i];
      if ($el =~ m/^--/) {
        push @args, $el;
      } elsif ($el =~ m/^-[\w\d]/) {
        die "Short options (-$el) not supported, try --option-name or --help\n";
      } else {
        $args[-1] .= " $el";
      }
    }

    my $maybe_params = join('|', @maybe_params);
    foreach my $arg (@args) {
      $arg =~ s/^--//; # Remove leading --
      $arg =~ tr/-/_/; # Convert - to _
      if ($arg =~ m/^($maybe_params)(?:[\s=]*(.+))?$/) {
        my $key = $1;
        my $val = $2 // true;
        $val = false if lc $val eq 'false';
        $args{$key} = $val;
      } else {
        die "Invalid argument: $arg\n";
      }
    }
  }

  if ($args{help}) {
    say "Available arguments:";
    say "\t--" . $_ for sort { $a cmp $b } @maybe_params;
    say '';
    say 'The following "special" arguments are not passed to HTTP::Server::Upload:';
    say "\t--help       Show help and exit";
    say "\t--dump_args  Show parsed arguments with Data::Dumper and exit";
    say '';
    say "All other arguments are passed to HTTP::Server::Upload->new(). See the";
    say "documentation of that module for details.";
    exit;
  }

  if ($args{dump_args}) {
    require Data::Dumper;
    say Data::Dumper::Dumper(\%args);
    exit;
  }

  return \%args;
};

my $server = HTTP::Server::Upload->new($parse_argv->()->%*);
undef $parse_argv; # Free memory
$server->start;
