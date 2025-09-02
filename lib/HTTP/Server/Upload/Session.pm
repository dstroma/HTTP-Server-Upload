use v5.42;
use experimental 'class';
package HTTP::Server::Upload::Session;
class HTTP::Server::Upload::Session {
  use HTTP::Status qw(:constants status_message);

  field $com_time     = time();
  field $com_errors   = 0;
  field $buf_size     = 1;
  field $req_buf      = '';
  field $hdr_buf      = '';
  field $res_buf      = '';

  field $bytes_to_read;
  field $bytes_written;
  field $request;
  field $request_raw;
  field $headers;
  field $headers_raw;
  field $query_string;
  field $response;

  field $out_file_base;
  field $head_fh;
  field $body_fh;
  field $prog_fh;

  field $client_fh    :param(fh);
  field $server       :reader :param;
  field $reading      :reader = 'request';
  field $writing      :reader;
  field $done         :reader;

  field $action      = '';
  field $is_upload   = false;
  field $upload_id;

  my method switch_to_write_mode () {
    $reading    = false;
    $writing    = true;
    $com_errors = 0;
    $com_time   = time();
    return;
  }

  my method mark_done () {
    $writing    = false;
    $done       = true;
    $client_fh  = undef;
    return;
  }

  method set_response ($http_status_or_psgi) {
    $self->&switch_to_write_mode;

    my $code = $http_status_or_psgi;
    my $msg  = status_message($code);
    my $cl   = length $msg;
    $response = [
      'HTTP/1.0 ' . $code . ' ' . $msg    ,
      'Server: upload-server-forking-3.pl',
      'Content-Type: text/plain'          ,
      'Content-Length: '.$cl              ,
      'Connection: close'                 ,
      ''                                  ,
      $msg                                ,
    ];
    return;
  }

  method read ($max_bytes = 1024*8, $max_cycles = 128) {
    START:
    return if $max_bytes <= 0 or $max_cycles <= 0;

    my $buf;
    my $read = sysread $client_fh, $buf, $buf_size;

    unless ($read) {
      $com_errors++;
      return $self->set_response(HTTP_REQUEST_TIMEOUT)
        if $com_errors > 60;
      return;
    }

    $com_time    = time;
    $com_errors  = 0;
    $max_bytes  -= $read;
    $max_cycles -= 1;

    # Read request line?
    if (not $request) {
      return $self->set_response(HTTP_BAD_REQUEST)
        if length $req_buf > int($server->max_header_size/2);

      $req_buf .= $buf;
      goto START
        unless $buf eq "\n";

      $request_raw = $req_buf;
      undef $req_buf;

      $request = [parse_requestline($request_raw)];
      $reading = 'head';

    # Read header line?
    } elsif (not $headers) {
      return $self->set_response(HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE)
        if length $hdr_buf > $server->max_header_size;

      $hdr_buf .= $buf;
      goto START
        unless length $hdr_buf > 1 and $hdr_buf =~ m/\r?\n\r?\n$/;

      $headers_raw = $hdr_buf;
      undef $hdr_buf;

      $headers = parse_headers($headers_raw);

      # Validate request
      return unless $self->is_request_valid;  # Will also set response
      return unless $is_upload;

      # Save headers
      open my $head_fh, '>', $self->full_filename_for('head')
        or return $self->set_error(500);
      print $head_fh $request_raw;
      print $head_fh $headers_raw;
      close $head_fh;

      # Get ready to read body
      $reading  = 'body';
      $buf_size = $max_bytes;
      $buf_size = $headers->{CONTENT_LENGTH}
        if $buf_size > $headers->{CONTENT_LENGTH};
      $bytes_to_read = $headers->{CONTENT_LENGTH};

    # Read body
    } else {
      unless (defined $body_fh) {
        unless (open $body_fh, '>', $self->full_filename_for('body')) {
          warn "Cannot open " . $self->full_filename_for('body') . ": $!";
          return $self->set_response(500);
        }
      }

      $bytes_to_read -= length $buf;
      $bytes_to_read  = 0
        if $bytes_to_read < 0;
      $buf_size    = $bytes_to_read
        if $bytes_to_read and $bytes_to_read < $buf_size;

      # Write body to file
      syswrite $body_fh, $buf;

      # Write progress to file
      unless ($prog_fh) {
        unless (open $prog_fh, '>', $self->full_filename_for('prog')) {
          warn "Cannot open progress file: $!";
          $prog_fh = -1;
        }
      }
      if (ref $prog_fh) {
        my $prog = $bytes_to_read
          ? int(100 * ($headers->{CONTENT_LENGTH} - $bytes_to_read) / $headers->{CONTENT_LENGTH})
          : 127;
        seek $prog_fh, 0, 0;
        syswrite $prog_fh, pack('c', $prog);
      }

      # Done reading?
      if ($bytes_to_read <= 0) {
        close $body_fh;
        close $prog_fh if $prog_fh;
        return $self->set_response(200);
      }

      # Repeat
      goto START;
    }
  }

  # Set a quota (max to write at once) so other connections don't have to wait
  method write ($max_bytes = 1024, $max_cycles = 128) {
    START:
    return if !$writing or $max_bytes <= 0 or $max_cycles <= 0;

    unless ($res_buf) {
      $res_buf  = ref $response eq 'ARRAY' ? join("\r\n", @$response) : $response;
      $bytes_written = 0;
    }

    while ($bytes_written < length $res_buf) {
      my $wrote = syswrite $client_fh, $res_buf, 1, $bytes_written;
      unless ($wrote) {
        $com_errors++;
        return $self->mark_done
          if $com_errors > 60;
        return;
      }

      $com_errors     = 0;
      $com_time       = time;
      $bytes_written += $wrote;
      $max_bytes     -= $wrote;
      $max_cycles    -= 1;

      # Using goto to avoid deep recursion
      goto START if $bytes_written < length $res_buf;
      return;
    }

    # Done writing
    $self->&mark_done;
  }

  method check {
    my $elapsed = time() - $com_time;
    if ($writing) {
      $self->&mark_done if $elapsed > 60;
    } elsif ($reading) {
      if ($reading eq 'body') {
        $self->set_response(200) if $elapsed > 900;
      } else {
        $self->set_response(200) if $elapsed > 60;
      }
    }
  }

  sub parse_requestline ($line) {
    my ($method, $uri, $proto) = $line =~ m/^(\w+)\s+(\S+)\s+(\S+)\r?\n$/;
    $uri =~ s{^https?://[^/]+}{}; # remove possible http://domain.com
    return (uc($method), $uri, $proto);
  }

  sub parse_headers ($string) {
    my %result = ();
    my @lines  = split /\r?\n/, $string;
    my $prevk;
    foreach my $line (@lines) {
      if (my ($continued) = $line =~ m/^\s+(\S+)$/) {
        return unless $prevk;
        $result{$prevk} .= $continued;
        next;
      }
      my ($k, $v) = $line =~ m/^([\w\d_-]+):\s*([^\r^\n]*)$/;
      $k = uc($k =~ tr/-/_/r);
      (exists $result{$k}
        ? $result{$k} .= "; $v"
        : $result{$k}  = $v
      );
      $prevk = $k;
    }
    return unless %result;
    \%result;
  }

  method is_request_valid () {
    # Determine action
    if ($request->[1] =~ m{^/upload/([\d\w_-]+)?(\?\S+)?$}) {
      $action       = 'upload';
      $upload_id    = $1 if defined $1 and length $1;
      $query_string = $2 if defined $2 and length $2;
    }

    if ($action eq 'upload' and $request->[0] eq 'POST') {
      say "Headers: " . join(', ', %$headers);
      unless ($headers->{CONTENT_TYPE} =~ m{^multipart/form-data}i) {
        say "content-type: " . $headers->{CONTENT_TYPE};
        return $self->set_response(HTTP_NOT_ACCEPTABLE);
      }
      $is_upload = true;
      unless (exists $headers->{CONTENT_LENGTH}) {
        return $self->set_response(HTTP_LENGTH_REQUIRED);
      }
      unless ($headers->{CONTENT_LENGTH} =~ m/^\d+$/) {
        return $self->set_response(HTTP_BAD_REQUEST);
      }
      unless ($headers->{CONTENT_LENGTH} <= $server->max_body_size) {
        return $self->set_response(HTTP_CONTENT_TOO_LARGE);
      }
      if ($server->require_id and not $upload_id) {
        return $self->set_response(404);
      }
      if ($upload_id and $server->require_placeholder
        and not $server->filename_base_exists($upload_id)
      ) {
        return $self->set_response(404);
      }
      if ($server->auth_required and not (
        defined $headers->{AUTHORIZATION}
        and $server->is_authorized($headers->{AUTHORIZATION})
      )) {
        return $self->set_response(403);
      }
      if ($server->no_overwrite) {
        return $self->set_response(HTTP_CONFLICT)
          if -e $self->full_filename_for('head')
          or -e $self->full_filename_for('body');
      }
    } else {
      $self->set_response(HTTP_METHOD_NOT_ALLOWED);
    }

    return true;
  }

  method full_filename_for ($filetype) {
    return join('.', $server->filename_base_for_upload($upload_id), $1)
      if $filetype =~ m/^(head|body|prog)/;
    return undef;
  }
}

1;

__END__

=head1 NAME

HTTP::Server::Upload::Session - Class representing client sessions

=head1 DESCRIPTION

This module is part of the HTTP::Server::Upload distribution, and is used
internally by that module. There should be no reason to use this class by
itself.

=head1 META

See HTTP::Server::Upload

=cut
