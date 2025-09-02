[![Actions Status](https://github.com/dstroma/HTTP-Server-Upload/actions/workflows/test.yml/badge.svg)](https://github.com/dstroma/HTTP-Server-Upload/actions)
# NAME

HTTP::Server::Upload - HTTP server just for uploads

# SYNOPSIS

    use HTTP::Server::Upload;

# DESCRIPTION

HTTP::Server::Upload is an HTTP server handling HTTP multipart/form-data
uploads using single-process, single-threaded, nonblocking IO to handle
multiple clients and providing progress tracking.

It is meant for light duty and to sit behind a reverse proxy server such as
nginx.

# FEATURES

- Low-ish memory footprint

    This distribution has been optimized for memory consumption. While a compiled
    C server would no doubt be much lower, memory use is about as low as can be
    for an interpreted language (less than 7 MiB, without leaking memory).
    By contrast, empty or trivial programs in other languages all use more than
    that:

        - Python3: 8.1MiB
        - Ruby:   10.9MiB
        - PHP:    13.4MiB
        - Node:   24.7MiB

- Listen on TCP or Unix domain socket.

    By default, will listen on port 6896. You can pass a different port or a path
    to a Unix domain socket via the listen option.

- Optional authorization

    This server provides a very simple authorizaton method. If authorization is
    enabled with the require\_auth => true option, it will parse the Authorization
    HTTP header and look for a line in an authorization file that matches it
    exactly.

- Optional file identification and placeholder system

    By default the server will assign each upload POST request an identifier. You
    can arrange to require the client supply this identifier with the require\_id
    option. Furthermore, you can require a "placeholder" to already exist with the
    require\_placeholder option (which implies require\_id). This allows you to
    ensure the server only accepts uploads that it is already expecting.

- Progress tracking

    Progress is stored in a .prog file as a single byte representing a signed 8-bit
    integer. Values from 0 to 100 represent the progress in percent; a value of 127
    represents a completed upload, while negative values represent errors.

# NON-FEATURES

This server does not parse request bodies into paramaters or individual files.
It is up to the user to do that by reading the created .head and .body files,
which contain the headers and request body supplied by the client in verbatim
HTTP format.

This server assumes disk IO will be fast and does not use nonblocking technique
to write data to disk.

# REQUIREMENTS

This module takes advantage of modern perl features such as subroutine
signatures and the new 'class' keyword, thus perl 5.42 is required.

# LICENSE

Copyright (C) 2025 Dondi Michael Stroma.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Dondi Michael Stroma <dstroma@gmail.com>

# POD ERRORS

Hey! **The above document had some coding errors, which are explained below:**

- Around line 221:

    You forgot a '=back' before '=head1'
