#!/bin/bash

##### DISCLAIMER ####################################################################################
# Project Page: https://github.com/berndhose/guacamole-upgrade
# Licence (GPL-3.0): https://github.com/berndhose/guacamole-upgrade/blob/master/LICENSE
# Report Issues: https://github.com/berndhose/guacamole-upgrade/issues
#
# WARNING: For use on RHEL/CentOS 7.x and up only.
#	-Use at your own risk!
#	-Use only for upgrading existing installations of Guacamole version 1.0.0 (and later)!
#	-Test prior to deploying on a production system!
#####################################################################################################

##### MUST READ #####################################################################################
# This script updates Guacamole installations only, which have been installed from Git with the 
# installation script from https://github.com/Zer0CoolX/guacamole-install-rhel
# MySQL,LDAP,RADIUS authenticators will be upgraded, if exisiting in extensions directory
#####################################################################################################

##### User defined directories, adjust to reflect current Tomcat and Guacamole installation #########
LIB_DIR="/var/lib/guacamole/"                           # Directory where Guacamole is installed
PROPERTIES_DIR="/etc/guacamole/"                        # Directory of Guacamole properties
INSTALL_DIR="/usr/local/src/guacamole/${GUAC_VER}/"     # Guacamole source installation dir
WEBAPPS_DIR="/var/lib/tomcat/webapps/"                  # Directory of Tomcat webapps
#####################################################################################################

##### Check if user is root or sudo
if ! [ $(id -u) = 0 ]; then echo "This script must be run as sudo or root"; exit 1 ; fi

##### Get the master version No. of Guacamole from Git
GUAC_VER=`curl -s https://raw.githubusercontent.com/apache/guacamole-server/master/configure.ac | grep 'AC_INIT([guacamole-server]*' | awk -F'[][]' -v n=2 '{ print $(2*n) }'`
GUAC_URL="git://github.com/apache/"
GUAC_SERVER="guacamole-server.git"
GUAC_CLIENT="guacamole-client.git"

# Get database, server, user and password from /etc/guacamole/guacamole.properties
DATABASE=$(grep -oP 'mysql-database:\K.*' ${PROPERTIES_DIR}guacamole.properties | awk '{print $1}')
MYSQL_SERVER=$(grep -oP 'mysql-hostname:\K.*' ${PROPERTIES_DIR}guacamole.properties | awk '{print $1}')
MYSQL_USER=$(grep -oP 'mysql-username:\K.*' ${PROPERTIES_DIR}guacamole.properties | awk '{print $1}')
MYSQL_PWD=$(grep -oP 'mysql-password:\K.*' ${PROPERTIES_DIR}guacamole.properties | awk '{print $1}')

# Get Tomcat name
TOMCAT=$(ls /etc/ | grep tomcat)

# Get Current Guacamole Version
OLDVERSION=$(grep -oP 'Guacamole.API_VERSION = "\K[0-9\.]+' ${WEBAPPS_DIR}guacamole/guacamole-common-js/modules/Version.js)

# Check if database can be accessed
export MYSQL_PWD
mysql -u ${MYSQL_USER} -h ${MYSQL_SERVER} ${DATABASE} -e"quit"
if [ $? -ne 0 ]; then
    echo "Failed to login to MySQL database ${DATABASE} on server ${MYSQL_SERVER} with user ${MYSQL_USER} and password ${MYSQL_PWD}"
    exit 1
fi

# Create backup of current database
mysqldump -u ${MYSQL_USER} -h ${MYSQL_SERVER} --add-drop-table ${DATABASE} > guacamole-db-dump.sql

#### Download new version from Git
# Delete install directory to ensure Git can be cloned (needs empty directory)
rm -rf ${INSTALL_DIR}${GUAC_VER}

# Create install directory
mkdir -vp ${INSTALL_DIR}${GUAC_VER}
cd ${INSTALL_DIR}${GUAC_VER}

# Download Guacamole server
git clone ${GUAC_URL}${GUAC_SERVER}
if [ $? -ne 0 ]; then
    echo "Failed to git clone guacamole server ${GUAC_VER}"
    exit 1
fi

# Download Guacamole client
git clone ${GUAC_URL}${GUAC_CLIENT} 		
if [ $? -ne 0 ]; then
    echo "Failed to git clone guacamole client ${GUAC_VER}"
    exit 1
fi

##### Stop Tomcat and guacamole server services
service ${TOMCAT} stop
service guacd stop

##### Compile and upgrade Guacamole Server
cd ${INSTALL_DIR}${GUAC_VER}/guacamole-server
autoreconf -fi
./configure --with-systemd-dir=/etc/systemd/system
make
make install
ldconfig
systemctl enable guacd

##### Compile and upgrade Guacamole Client
cd ${INSTALL_DIR}${GUAC_VER}/guacamole-client
export PATH=/opt/maven/bin:${PATH}
mvn package
cp -vf ./guacamole/target/guacamole-${GUAC_VER}.war ${LIB_DIR}guacamole.war

##### Update authenticators
cd ${INSTALL_DIR}${GUAC_VER}

# Get JDBC MySQL authenticator from compiled client and copy to Tomcat Guacamole client 
if [ -e ${LIB_DIR}extensions/guacamole-auth-jdbc-mysql-* ]; then
    rm -rf ${LIB_DIR}extensions/guacamole-auth-jdbc-mysql*  
    find ./guacamole-client/extensions -name "guacamole-auth-jdbc-mysql-${GUAC_VER}.jar" -exec cp -vf {} ${LIB_DIR}extensions/ \;
fi

# Get LDAP authenticator from compiled client and copy to Tomcat guacamole client
if [ -e ${LIB_DIR}extensions/guacamole-auth-ldap-*.jar ]; then
    rm -rf ${LIB_DIR}extensions/guacamole-auth-ldap*
    find ./guacamole-client/extensions -name "guacamole-auth-ldap-${GUAC_VER}.jar" -exec cp -vf {} ${LIB_DIR}extensions/ \;
fi

# Get RADIOS authenticator from compiled client and copy to Tomcat guacamole client
if [ -e ${LIB_DIR}extensions/guacamole-auth-radius-*.jar ]; then
    rm -rf ${LIB_DIR}extensions/guacamole-auth-radius*
    find ./guacamole-client/extensions -name "guacamole-radius-ldap-${GUAC_VER}.jar" -exec cp -vf {} ${LIB_DIR}extensions/ \;
fi

##### Update SQL database
cd ${INSTALL_DIR}${GUAC_VER}/guacamole-client/extensions
# Get list of SQL Upgrade Files
UPGRADEFILES=($(ls -1 ./guacamole-auth-jdbc/modules/guacamole-auth-jdbc-mysql/schema/upgrade/ | sort -V))

# Compare SQL Upgrage Files against old Guacamole database version, apply upgrades as needed
for FILE in ${UPGRADEFILES[@]}
do
    FILEVERSION=$(echo ${FILE} | grep -oP 'upgrade-pre-\K[0-9\.]+(?=\.)')
    if [[ $(echo -e "${FILEVERSION}\n${OLDVERSION}" | sort -V | head -n1) == ${OLDVERSION} && ${FILEVERSION} != ${OLDVERSION} ]]
    then
        echo "Patching ${DATABASE} with ${FILE}"
        mysql -u ${MYSQL_USER} -h ${MYSQL_SERVER} ${DATABASE} < ./guacamole-auth-jdbc/modules/guacamole-auth-jdbc-mysql/schema/upgrade/${FILE}
    fi
done

##### Manage Selinux settings
# Guacamole Client Context
semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}guacamole.war"
restorecon -v "${LIB_DIR}guacamole.war"

# Guacamole JDBC Extension Context
if [ -e ${LIB_DIR}extensions/guacamole-auth-jdbc-mysql-* ]; then
    semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}extensions/guacamole-auth-jdbc-mysql-${GUAC_VER}.jar"
    restorecon -v "${LIB_DIR}extensions/guacamole-auth-jdbc-mysql-${GUAC_VER}.jar"
fi

# Guacamole LDAP Extension Context
if [ -e ${LIB_DIR}extensions/guacamole-auth-ldap-*.jar ]; then
    semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}extensions/guacamole-auth-ldap-${GUAC_VER}.jar"
    restorecon -v "${LIB_DIR}extensions/guacamole-auth-ldap-${GUAC_VER}.jar"
fi

# Guacamole RADIUS Extension Context
if [ -e ${LIB_DIR}extensions/guacamole-radius-ldap-*.jar ]; then
    semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}extensions/guacamole-auth-radius-${GUAC_VER}.jar"
    restorecon -v "${LIB_DIR}extensions/guacamole-auth-radius-${GUAC_VER}.jar"
fi

##### Start services
# Cleanup outdated expanded Guacamole client directory in Tomcat, will be populated again when Tomcat restarts
rm -rf ${WEBAPPS_DIR}guacamole
# Start Tomcat and Guacamole server
service ${TOMCAT} start
service guacd start

exit 0
