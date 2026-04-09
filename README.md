[![Actions Status](https://github.com/dstroma/HTTP-Server-Upload/actions/workflows/test.yml/badge.svg)](https://github.com/dstroma/HTTP-Server-Upload/actions)
# NAME

HTTP::Server::Upload - HTTP server just for uploads

# SYNOPSIS

    use HTTP::Server::Upload;
    my $server = HTTP::Server::Upload->new(
      listen    => '/run/upload.sock', # override default port 6896
      store_dir => '/var/uploads',     # specify explicit storage location
    );
    $server->start;

    # Or use the command line script (example with custom port)
    $ http-server-upload.pl --listen=8888 --daemonize=1

# DESCRIPTION

HTTP::Server::Upload is a lightweight standalone HTTP server specialized
for receiving large multipart/form-data uploads with minimal memory usage
and filesystem-based progress tracking. It is designed to run behind a
reverse proxy such as nginx and integrate with an external application
server that manages upload preparation and post-processing.

It runs a single process and uses nonblocking IO to handle simultaneous
clients, but is designed for light duty (one or a small number of clients
at a time).

## Features

- Relatively low memory footprint

    Server memory usage is approximately 7 MiB at idle.

- Listen on TCP or Unix domain socket.

    By default, the server will listen on port 6896. You can pass a different port
    or a path to a Unix domain socket via the listen parameter.

- Optional authorization

    This server provides a very simple authorization method. If authorization is
    enabled with the auth\_required => true parameter, it will parse the
    Authorization HTTP header and look for a line in an authorization file that
    matches it exactly. For example, the auth file could contain lines such as:

         Basic YWxhZGRpbjpvcGVuc2VzYW1l
         Bearer abc123token

    And the Authorization header received from the client must match one of these.

- Optional file identification and placeholder system

    By default the server will assign each upload POST request an identifier. You
    can arrange to require the client supply this identifier with the require\_id
    option. Furthermore, you can require a "placeholder" to already exist with the
    require\_placeholder option (which implies require\_id). This allows you to
    ensure the server only accepts uploads that it is already expecting.

- File-based progress tracking

    Progress is stored in a .prog file as a single byte representing a signed 8-bit
    integer. Values from 0 to 100 represent the progress in percent; a value of 127
    represents a completed upload, while negative values represent errors.

## Non-Features

This server does not parse request bodies into parameters or individual files.
It is up to the user to do that by reading the created .head and .body files,
which contain the headers and request body supplied by the client in verbatim
HTTP format.

Disk I/O is blocking. The server assumes uploads are written to fast local
storage.

# COMMAND LINE START SCRIPT

This module is bundled with a command line script called http-server-upload.pl.
Command line arguments should be prefixed with two hyphens (--) and will be
passed to HTTP::Server::Upload->new().

The special command line arguments **--help** and **--dump\_args** will output a help
message or a list of parsed arguments and immediately exit.

Multiword argument names can use hyphens or underscores interchangeably; e.g.
\--store-dir is equivalent to --store\_dir.

Keys and values can be separated by whitespace, an equal sign, or nothing.

    # Examples
    http-server-upload.pl --help
    http-server-upload.pl --dump-args
    http-server-upload.pl --listen 81 --store-dir=/tmp/uploads --daemonizetrue

# CONSTRUCTOR

- **new PARAMS**

    Returns a new [HTTP::Server::Upload](https://metacpan.org/pod/HTTP%3A%3AServer%3A%3AUpload) object constructed according to PARAMS,
    where PARAMS are name/value pairs. Valid PARAMS are listed below with their
    default values. All PARAMS are optional.

    - **daemonize** => false

        Pass a true value to daemonize the server, which will fork once and the
        parent will exit. More control over behavior can be accomplished by writing
        a custom server start script.

    - **log\_file** => undef

        A file to use to log server information. If specified, STDOUT and STDERR
        will be redirected here.

    - **listen** => 6896

        A TCP/IP port number or unix domain socket file location.

    - **listen\_queue** => 10

        Queue size for listen, passed to the appropriate IO::Socket class constructor.

    - **max\_clients** => 10

        Maximum number of simultaneous client connections.

    - **auth\_required** => false

        Whether to require authorization before accepting an upload from a client.

    - **auth\_file** => ./tmp/uploads/.auth

        A file with authorization information, explained above.
        Note the default is relative to the present working directory.

    - **store\_dir** => ./tmp/uploads

        Directory to store file uploads and metadata.
        Note the default is relative to the present working directory.

    - **require\_id** => false

        Whether to require the client to assign their upload an identification
        (number or string).

        If true, the client must specify an id in the POST location, e.g.:

            POST /upload/123456
            POST /upload/file-xyz-789

        The id can be any word character, digit, underscore (\_), or hyphen (-)
        with arbitrary length.

    - **require\_placeholder** => false

        If true, the upload identification string must be pre-chosen by the
        application server which negotiates the upload (or by some other means),
        which should do so by creating a directory (if use\_subdir=true) or a placeholder
        file (if use\_subdir=false) with no extension or one of the following:

            .ok
            .ready
            .prog
            .head
            .body

        The directory or placeholder file root name should be the desired
        upload\_id, subject to the specification described in the require\_id option.

        If true, implies require\_id = true.

    - **no\_overwrite** => true

        If true, refuse to overwrite a previous upload session with a new one of the
        same name.

    - **use\_subdir** => true

        Put uploads and metadata in a separate directory per client connection.

    - **select\_timeout\_busy** => 0.05

        Timeout in seconds to pass to IO::Select if at least one client is connected.

    - **select\_timeout\_idle** => 0.30

        Timeout in seconds to pass to IO::Select if no clients are connected.

    - **read\_timeout\_head** => 60

        Timeout for reading the HTTP header from the client. The client will be
        disconnected if no data is received for this number of seconds.

    - **read\_timeout\_body** => 60\*15

        Timeout for reading the HTTP body from the client. The client will be
        disconnected if no data is received for this number of seconds.

    - **write\_timeout** => 60

        Timeout for writing HTTP response data to the client. The client will be
        disconnected if no data can be sent for this number of seconds.

    - **max\_header\_size** => $number\_of\_bytes (default 64 KiB)

        Maximum size of HTTP headers in bytes. The server will transmit an error
        message to the client if the HTTP headers exceed this size.

    - **max\_body\_size** => $number\_of\_bytes (default 4 GiB)

        Maximum size of HTTP body in bytes. The server will transmit an error
        message to the client if the HTTP header indicates that this body size will be
        exceeded.

    - **max\_bytes\_at\_a\_time** => 4\*KiB

        Maximum number of bytes to exchange with a client before switching to a
        different one. May be useful for performance tuning. Reducing this number may
        help if you have slow clients and increasing it may help if your clients are
        fast.

    - **max\_cycles\_at\_a\_time** => 128

        Maximum number of reads from or writes to a specific client before switching
        to a different one. May be useful for performance tuning.
        Reducing this number may help if you have many simultaneous clients
        and increasing it may help if you have one or few simultaneous clients.

# OBJECT METHODS

- **start**

    Starts the server event loop, and prints an advisory message to STDERR.

- **stop**

    Stops the server, prints an advisory message to STDERR, and closes log handles.

# UPLOAD WORKFLOW

It is assumed HTTP::Server::Upload will be working with a web application
server (which can be written in any language). The web application server is
responsible for presenting the end user an HTML upload form, in most cases
should assign the client an upload identification, create the required
placeholder directory or file as described under the require\_placeholder
option, and then may read the upload progress from the .prog file. When the
upload is finished, your application should then read and parse the .head
and .body files for parameters, filenames, and file contents, and then save
the uploaded file(s) to the desired locations.

The client should post file uploads to /upload or /upload/upload-id using the
multipart/form-data Content-Type. This can be done behind a reverse proxy such
as with nginx configured like the below example:

>     # Example nginx.conf entry
>     # Arbitrary location can be proxied to /upload
>     location /my-web-app/user-area/upload/ {
>         # Pass to HTTP::Server::Upload running on a unix socket
>         proxy_pass             http://unix:/path/to/socket.sock:/upload/;
>
>         # Turn off buffering so progress can be tracked
>         proxy_request_buffering off;
>
>         # Optional limits
>         client_max_body_size    4g;
>         proxy_read_timeout      2h;
>
>         # Typical custom headers for reference later by your application
>         proxy_set_header        X-Real-IP           $remote_addr;
>         proxy_set_header        X-Forwarded-For     $proxy_add_x_forwarded_for;
>
>         # When HTTP::Server::Upload is running with auth_required
>         # Alternatively, have the client supply this header
>         proxy_set_header        Authorization       "Bearer 123456";
>     }

## Generated Files

> A file upload will result in the following files being created:
>
>     $server->store_dir . "/upload-$upload_id.head"  # raw HTTP headers
>     $server->store_dir . "/upload-$upload_id.body"  # raw HTTP body
>     $server->store_dir . "/upload-$upload_id.prog"  # progress byte
>
> If the use\_subdir option is on, the files would be named instead:
>
>     $server->store_dir . "/$upload_id/upload.head"  # raw HTTP headers
>     $server->store_dir . "/$upload_id/upload.body"  # raw HTTP body
>     $server->store_dir . "/$upload_id/upload.prog"  # progress byte

# SECURITY CONSIDERATIONS

HTTP::Server::Upload is intended to run behind a reverse proxy.

It does not implement TLS and it performs only simple Authorization header
matching and should not be exposed directly to the Internet without
considering additional protections.

Disk writes are blocking and uploads are written directly to store\_dir.
Ensure the directory resides on trusted storage and has sufficient capacity.

At the same time, this module offers several security advantages. You can
reduce the front-end server's max body size for non-upload locations, and
only accept uploads you are expecting, versus allowing your front-end
to accept uploads of large sizes to all locations.

# SYSTEM REQUIREMENTS

This module takes advantage of modern perl features such as subroutine
signatures and the new 'class' keyword, thus perl 5.42 is required.

# LICENSE

Copyright (C) 2025, 2026 Dondi Michael Stroma.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Dondi Michael Stroma <dstroma@gmail.com>
