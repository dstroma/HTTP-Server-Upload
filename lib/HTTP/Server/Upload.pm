use v5.42;
use experimental 'class';
class   HTTP::Server::Upload 0.01 {
  use IO::Socket ();
  use IO::Select ();
  use HTTP::Server::Upload::Session ();
  use constant KiB => 1024;
  use constant MiB => 1024*KiB;
  use constant GiB => 1024*MiB;

  field $daemonize            :param         = false;
  field $log_file             :param         = undef;
  field $log_fh;
  field $listen               :param         = 6896;
  field $listen_queue         :param         = 10;
  field $max_clients          :param         = 5;
  field $auth_required        :param :reader = false;
  field $auth_file            :param         = './tmp/uploads/.auth';
  field $store_dir            :param :reader = './tmp/uploads';
  field $require_id           :param :reader = false; # If true the client must supply an ID
  field $require_placeholder  :param :reader = false;
  field $no_overwrite         :param :reader = true;
  field $use_subdir           :param         = true;  # If true, will use a subdir for each upload
  field $select_timeout_busy  :param         = 0.05;
  field $select_timeout_idle  :param         = 0.30;
  field $read_timeout_head    :param :reader = 60;
  field $read_timeout_body    :param :reader = 60 * 15;
  field $write_timeout        :param :reader = 60;
  field $max_header_size      :param :reader = 64 * KiB;
  field $max_body_size        :param :reader =  4 * GiB;
  field $max_bytes_at_a_time  :param         =  4 * KiB;
  field $max_cycles_at_a_time :param         = 128;
  field $server_io;
  field $forked;

  ADJUST  { chop $store_dir if substr($store_dir, -1, 1) =~ m`[\/\\]` }
  DESTROY { $_[0]->stop }

  method start {
    $forked = fork() and exit if $daemonize;
    $self->redirect_output    if $log_file;
    $self->check_authfile     if $auth_required;

    my %std_args = (Listen => $listen_queue, Blocking => 0);
    if ($listen =~ m/^\d+$/) {
      require IO::Socket::INET;
      $server_io = IO::Socket::INET->new(%std_args, LocalPort => $listen, ReuseAddr => 1)
    } else {
      require IO::Socket::UNIX;
      $server_io = IO::Socket::UNIX->new(%std_args, Local => $listen)
    }
    $server_io or die($IO::Socket::errstr || $@ || $! || 'Unknown error');

    warn "Server $server_io (PID $$) starting. Listening on $listen.\n";
    $self->serve;
  }

  method stop {
    return if $forked;
    warn "Server $server_io (PID $$) stopping.\n";
    close $log_fh if $log_fh;
  }

  method redirect_output () {
    open $log_fh, '>>', $log_file
      or die "Cannot open $log_file: $!\n";
    *STDOUT = $log_fh;
    *STDERR = $log_fh;
  }

  method serve () {
    my $req_count = 0;
    my $select    = IO::Select->new($server_io);
    my %sessions  = ();
    my $cleanup_time;

    while (1) {
      my $select_timeout = %sessions ? $select_timeout_busy : $select_timeout_idle;

      # Read?
      for my $fh ($select->can_read($select_timeout)) {
        # New connection?
        if ($fh == $server_io) {
          my $client = $server_io->accept;
          $select->add($client);

          $sessions{$client} = HTTP::Server::Upload::Session->new(fh => $client, server => $self);
          $req_count++;
          next;
        }

        # Existing connection (reading)
        my $session = $sessions{$fh};
        $session->read($max_bytes_at_a_time, $max_cycles_at_a_time) if $session->reading;
      }

      # Write?
      for my $fh ($select->can_write($select_timeout)) {
        my $session = $sessions{$fh};
        $session->write($max_bytes_at_a_time, $max_cycles_at_a_time) if $session->writing;
      }

      # Purge completed sessions (do not use keys %sessions, it won't work)
      foreach my $fh ($select->handles) {
        if (my $session = $sessions{$fh}) {
          if ($session->done) {
            $select->remove($fh);
            close $fh;
            delete $sessions{$fh};
            next;
          }
          $session->check;
        }
      }

      # Clean up
      if (!$cleanup_time or time() > $cleanup_time + 60) {
        $self->check_authfile if $auth_required;
        $cleanup_time = time();
      }

    } #while
  } #serve

  # Authorization
  field %auth;
  field $authfile_mtime;
  method check_authfile ($force_reload = undef) {
    return unless $auth_required;
    my $authfile_mtime_now = (stat($auth_file))[9];

    if ($force_reload or !$authfile_mtime or $authfile_mtime != $authfile_mtime_now) {
      if (open my $fh, '<', $auth_file) {
        %auth = ();
        while (my $line = <$fh>) {
          $line =~ m/^\s*(.*)\s*$/;
          $auth{$1} = true if $1;
        }
        close $fh;
        $authfile_mtime = (stat($auth_file))[9];
      } else {
        die sprintf("WARNING - Cannot open auth file %s! $!", $auth_file);
        return;
      }
    }

    warn sprintf("NOTICE - No entries in auth file %s.\n", $auth_file) unless %auth;
    return;
  }

  method is_authorized ($value) {
    $auth{$value};
  }

  method filename_base_for_upload ($ident) {
    if ($use_subdir) {
      return "$store_dir/$ident/upload";
    } else {
      return "$store_dir/upload-$ident";
    }
  }

  method filename_base_exists ($ident) {
    if ($use_subdir) {
      return true if -d "$store_dir/$ident/";
    } else {
      # return inside grep = a hackish 'any'
      grep {
        return true if -e $self->filename_base_for_upload($ident) . $_
      } ('', '.head', '.body', '.prog', '.ok', '.ready');
    }
    return false;
  }

} #class

1;

__END__

=head1 NAME

HTTP::Server::Upload - HTTP server just for uploads

=head1 SYNOPSIS

    use HTTP::Server::Upload;

=head1 DESCRIPTION

HTTP::Server::Upload is an HTTP server handling HTTP multipart/form-data
uploads using single-process, single-threaded, nonblocking IO to handle
multiple clients and providing progress tracking.

It is meant for light duty and to sit behind a reverse proxy server such as
nginx.

=head1 FEATURES

=over 4

=item Low-ish memory footprint

This distribution has been optimized for memory consumption. While a compiled
C server would no doubt be much lower, memory use is about as low as can be
for an interpreted language (less than 7 MiB, without leaking memory).
By contrast, empty or trivial programs in other languages all use more than
that:

 - Python3: 8.1MiB
 - Ruby:   10.9MiB
 - PHP:    13.4MiB
 - Node:   24.7MiB

=item Listen on TCP or Unix domain socket.

By default, will listen on port 6896. You can pass a different port or a path
to a Unix domain socket via the listen option.

=item Optional authorization

This server provides a very simple authorizaton method. If authorization is
enabled with the require_auth => true option, it will parse the Authorization
HTTP header and look for a line in an authorization file that matches it
exactly.

=item Optional file identification and placeholder system

By default the server will assign each upload POST request an identifier. You
can arrange to require the client supply this identifier with the require_id
option. Furthermore, you can require a "placeholder" to already exist with the
require_placeholder option (which implies require_id). This allows you to
ensure the server only accepts uploads that it is already expecting.

=item Progress tracking

Progress is stored in a .prog file as a single byte representing a signed 8-bit
integer. Values from 0 to 100 represent the progress in percent; a value of 127
represents a completed upload, while negative values represent errors.

=back

=head1 NON-FEATURES

This server does not parse request bodies into paramaters or individual files.
It is up to the user to do that by reading the created .head and .body files,
which contain the headers and request body supplied by the client in verbatim
HTTP format.

This server assumes disk IO will be fast and does not use nonblocking technique
to write data to disk.

=head1 REQUIREMENTS

This module takes advantage of modern perl features such as subroutine
signatures and the new 'class' keyword, thus perl 5.42 is required.

=head1 LICENSE

Copyright (C) 2025 Dondi Michael Stroma.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Dondi Michael Stroma E<lt>dstroma@gmail.comE<gt>

=cut
