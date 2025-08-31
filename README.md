
# NAME

HTTP::Server::Upload - HTTP server just for uploads

# SYNOPSIS

    use HTTP::Server::Upload;

# DESCRIPTION

HTTP::Server::Upload is an HTTP server handling HTTP multipart/form-data
uploads using single-process, single-threaded, nonblocking IO to handle
multiple clients and providing progress tracking.

It is might for light duty and to sit behind a reverse proxy server such as
nginx.

# LICENSE

Copyright (C) 2025 Dondi Michael Stroma.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Dondi Michael Stroma <dstroma@gmail.com>
