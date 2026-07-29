# Dockerfile for OpenLDAP client
FROM registry.access.redhat.com/ubi8/ubi-minimal:latest

LABEL name="openldap-client" \
      vendor="Custom" \
      version="1.0" \
      release="1" \
      summary="OpenLDAP client tools" \
      description="OpenLDAP client tools for LDAP operations" \
      io.k8s.description="OpenLDAP client tools for LDAP operations" \
      io.k8s.display-name="OpenLDAP Client" \
      io.openshift.tags="ldap,client,openldap"

# Install OpenLDAP client tools
RUN microdnf update -y && \
    microdnf install -y openldap-clients ca-certificates && \
    microdnf clean all

# Create a non-root user
RUN microdnf install -y shadow-utils && \
    useradd -u 1001 -r -g 0 -s /sbin/nologin \
      -c "OpenLDAP client user" ldap-user && \
    microdnf remove -y shadow-utils && \
    microdnf clean all

# Set working directory
WORKDIR /tmp

# Set user
USER 1001

# Set entrypoint
ENTRYPOINT ["ldapsearch"]
CMD ["--help"]

