# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# compose-demo service image. Same base as the harness (.env BASE_IMAGE_PATH:
# Ubuntu 22.04 from Amazon ECR Public), pinned by digest. The server and its
# checks use Perl core modules only (perl-base is part of the ubuntu base), so
# the build pulls the base image from ECR Public and downloads nothing else.
FROM public.ecr.aws/ubuntu/ubuntu:22.04@sha256:bea3e9ce454d8bbd1fc005efd77dd06e9ac3bcdeceb3efd9d2e0c7d6fc1a11e7
COPY app/ /app/
USER nobody
CMD ["perl", "/app/server.pl"]
