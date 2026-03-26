use v5.42;
use experimental 'class';
class HTTP::Server::Upload 0.01 {
  use IO::Socket ();
  use IO::Select ();
  use HTTP::Server::Upload::Cx ();
  use constant KiB => 1024;
  use constant MiB => 1024*KiB;
  use constant GiB => 1024*MiB;

  field $daemonize            :param         = false;
  field $log_file             :param         = undef;
  field $log_fh;
  field $listen               :param         = 6896;
  field $listen_queue         :param         = 10;
  field $max_clients          :param         = 10;
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
  field $started                             = false;

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
    $started = true;
  }

  method stop {
    return if $forked or not $started;
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

          # Check for too many connections
          if (%sessions >= $max_clients) {
            warn "Reached client limit, refused new connection.\n";
            $client->close;
            next;
          }

          $select->add($client);
          $sessions{$client} = HTTP::Server::Upload::Cx->new(fh => $client, server => $self);
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
    return "$store_dir/$ident/upload" if $use_subdir;
    return "$store_dir/upload-$ident";
  }

  method filename_base_exists ($ident) {
    return -d "$store_dir/$ident/" ? true : false if $use_subdir;
    grep {
      return true if -e $self->filename_base_for_upload($ident) . $_
    } ('', '.head', '.body', '.prog', '.ok', '.ready');
    return false;
  }

} #class

__END__

=head1 NAME

HTTP::Server::Upload - HTTP server just for uploads

=head1 SYNOPSIS

    use HTTP::Server::Upload;
    my $server = HTTP::Server::Upload->new(
      listen    => '/run/upload.sock', # override default port 6896
      store_dir => '/var/uploads',     # specify explicit storage location
    );
    $server->start;

=head1 DESCRIPTION

HTTP::Server::Upload is a lightweight standalone HTTP server specialized
for receiving large multipart/form-data uploads with minimal memory usage
and filesystem-based progress tracking. It is designed to run behind a
reverse proxy such as nginx and integrate with an external application
server that manages upload preparation and post-processing.

It runs a single process and uses nonblocking IO to handle simultaneous
clients, but is designed for light duty (one or a small number of clients
at a time).

=head2 Features

=over 4

=item Relatively low memory footprint

Server memory usage is approximately 7 MiB at idle.

=item Listen on TCP or Unix domain socket.

By default, the server will listen on port 6896. You can pass a different port
or a path to a Unix domain socket via the listen parameter.

=item Optional authorization

This server provides a very simple authorization method. If authorization is
enabled with the auth_required => true parameter, it will parse the
Authorization HTTP header and look for a line in an authorization file that
matches it exactly. For example, the auth file could contain lines such as:

     Basic YWxhZGRpbjpvcGVuc2VzYW1l
     Bearer abc123token

And the Authorization header received from the client must match one of these.

=item Optional file identification and placeholder system

By default the server will assign each upload POST request an identifier. You
can arrange to require the client supply this identifier with the require_id
option. Furthermore, you can require a "placeholder" to already exist with the
require_placeholder option (which implies require_id). This allows you to
ensure the server only accepts uploads that it is already expecting.

=item File-based progress tracking

Progress is stored in a .prog file as a single byte representing a signed 8-bit
integer. Values from 0 to 100 represent the progress in percent; a value of 127
represents a completed upload, while negative values represent errors.

=back

=head2 Non-Features

This server does not parse request bodies into parameters or individual files.
It is up to the user to do that by reading the created .head and .body files,
which contain the headers and request body supplied by the client in verbatim
HTTP format.

Disk I/O is blocking. The server assumes uploads are written to fast local
storage.

=head1 COMMAND LINE START SCRIPT

This module is bundled with a command line script called http-server-upload.pl.
Command line arguments should be prefixed with two hyphens (--) and will be
passed to HTTP::Server::Upload->new().

The special command line arguments B<--help> and B<--dump_args> will output a help
message or a list of parsed arguments and immediately exit.

Multiword argument names can use hyphens or underscores interchangeably; e.g.
--store-dir is equivalent to --store_dir.

Keys and values can be separated by whitespace, an equal sign, or nothing.

    # Examples
    http-server-upload.pl --help
    http-server-upload.pl --dump-args
    http-server-upload.pl --listen 81 --store-dir=/tmp/uploads --daemonizetrue

=head1 CONSTRUCTOR

=over 4

=item B<new PARAMS>

Returns a new L<HTTP::Server::Upload> object constructed according to PARAMS,
where PARAMS are name/value pairs. Valid PARAMS are listed below with their
default values. All PARAMS are optional.

=over 4

=item B<daemonize> => false

Pass a true value to daemonize the server, which will fork once and the
parent will exit. More control over behavior can be accomplished by writing
a custom server start script.

=item B<log_file> => undef

A file to use to log server information. If specified, STDOUT and STDERR
will be redirected here.

=item B<listen> => 6896

A TCP/IP port number or unix domain socket file location.

=item B<listen_queue> => 10

Queue size for listen, passed to the appropriate IO::Socket class constructor.

=item B<max_clients> => 10

Maximum number of simultaneous client connections.

=item B<auth_required> => false

Whether to require authorization before accepting an upload from a client.

=item B<auth_file> => ./tmp/uploads/.auth

A file with authorization information, explained above.
Note the default is relative to the present working directory.

=item B<store_dir> => ./tmp/uploads

Directory to store file uploads and metadata.
Note the default is relative to the present working directory.

=item B<require_id> => false

Whether to require the client to assign their upload an identification
(number or string).

If true, the client must specify an id in the POST location, e.g.:

   POST /upload/123456
   POST /upload/file-xyz-789

The id can be any word character, digit, underscore (_), or hyphen (-)
with arbitrary length.

=item B<require_placeholder> => false

If true, the upload identification string must be pre-chosen by the
application server which negotiates the upload (or by some other means),
which should do so by creating a directory (if use_subdir=true) or a placeholder
file (if use_subdir=false) with no extension or one of the following:

    .ok
    .ready
    .prog
    .head
    .body

The directory or placeholder file root name should be the desired
upload_id, subject to the specification described in the require_id option.

If true, implies require_id = true.

=item B<no_overwrite> => true

If true, refuse to overwrite a previous upload session with a new one of the
same name.

=item B<use_subdir> => true

Put uploads and metadata in a separate directory per client connection.

=item B<select_timeout_busy> => 0.05

Timeout in seconds to pass to IO::Select if at least one client is connected.

=item B<select_timeout_idle> => 0.30

Timeout in seconds to pass to IO::Select if no clients are connected.

=item B<read_timeout_head> => 60

Timeout for reading the HTTP header from the client. The client will be
disconnected if no data is received for this number of seconds.

=item B<read_timeout_body> => 60*15

Timeout for reading the HTTP body from the client. The client will be
disconnected if no data is received for this number of seconds.

=item B<write_timeout> => 60

Timeout for writing HTTP response data to the client. The client will be
disconnected if no data can be sent for this number of seconds.

=item B<max_header_size> => $number_of_bytes (default 64 KiB)

Maximum size of HTTP headers in bytes. The server will transmit an error
message to the client if the HTTP headers exceed this size.

=item B<max_body_size> => $number_of_bytes (default 4 GiB)

Maximum size of HTTP body in bytes. The server will transmit an error
message to the client if the HTTP header indicates that this body size will be
exceeded.

=item B<max_bytes_at_a_time> => 4*KiB

Maximum number of bytes to exchange with a client before switching to a
different one. May be useful for performance tuning. Reducing this number may
help if you have slow clients and increasing it may help if your clients are
fast.

=item B<max_cycles_at_a_time> => 128

Maximum number of reads from or writes to a specific client before switching
to a different one. May be useful for performance tuning.
Reducing this number may help if you have many simultaneous clients
and increasing it may help if you have one or few simultaneous clients.

=back

=back

=head1 OBJECT METHODS

=over 4

=item B<start>

Starts the server event loop, and prints an advisory message to STDERR.

=item B<stop>

Stops the server, prints an advisory message to STDERR, and closes log handles.

=back

=head1 UPLOAD WORKFLOW

It is assumed HTTP::Server::Upload will be working with a web application
server (which can be written in any language). The web application server is
responsible for presenting the end user an HTML upload form, in most cases
should assign the client an upload identification, create the required
placeholder directory or file as described under the require_placeholder
option, and then may read the upload progress from the .prog file. When the
upload is finished, your application should then read and parse the .head
and .body files for parameters, filenames, and file contents, and then save
the uploaded file(s) to the desired locations.

The client should post file uploads to /upload or /upload/upload-id using the
multipart/form-data Content-Type. This can be done behind a reverse proxy such
as with nginx configured like the below example:

=over 4

    # Example nginx.conf entry
    # Arbitrary location can be proxied to /upload
    location /my-web-app/user-area/upload/ {
        # Pass to HTTP::Server::Upload running on a unix socket
        proxy_pass             http://unix:/path/to/socket.sock:/upload/;

        # Turn off buffering so progress can be tracked
        proxy_request_buffering off;

        # Optional limits
        client_max_body_size    4g;
        proxy_read_timeout      2h;

        # Typical custom headers for reference later by your application
        proxy_set_header        X-Real-IP           $remote_addr;
        proxy_set_header        X-Forwarded-For     $proxy_add_x_forwarded_for;

        # When HTTP::Server::Upload is running with auth_required
        # Alternatively, have the client supply this header
        proxy_set_header        Authorization       "Bearer 123456";
    }

=back

=head2 Generated Files

=over 4

A file upload will result in the following files being created:

    $server->store_dir . "/upload-$upload_id.head"  # raw HTTP headers
    $server->store_dir . "/upload-$upload_id.body"  # raw HTTP body
    $server->store_dir . "/upload-$upload_id.prog"  # progress byte

If the use_subdir option is on, the files would be named instead:

    $server->store_dir . "/$upload_id/upload.head"  # raw HTTP headers
    $server->store_dir . "/$upload_id/upload.body"  # raw HTTP body
    $server->store_dir . "/$upload_id/upload.prog"  # progress byte


=back

=head1 SECURITY CONSIDERATIONS

HTTP::Server::Upload is intended to run behind a reverse proxy.

It does not implement TLS and it performs only simple Authorization header
matching and should not be exposed directly to the Internet without
considering additional protections.

Disk writes are blocking and uploads are written directly to store_dir.
Ensure the directory resides on trusted storage and has sufficient capacity.

At the same time, this module offers several security advantages. You can
reduce the front-end server's max body size for non-upload locations, and
only accept uploads you are expecting, versus allowing your front-end
to accept uploads of large sizes to all locations.

=head1 SYSTEM REQUIREMENTS

This module takes advantage of modern perl features such as subroutine
signatures and the new 'class' keyword, thus perl 5.42 is required.

=head1 LICENSE

Copyright (C) 2025, 2026 Dondi Michael Stroma.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Dondi Michael Stroma E<lt>dstroma@gmail.comE<gt>

=cut
