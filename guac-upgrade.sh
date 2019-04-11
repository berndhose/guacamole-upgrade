#!/bin/bash

##################################       DISCLAIMER             #####################################
# Project Page: https://github.com/berndhose/guacamole-upgrade										#
# Licence (GPL-3.0): https://github.com/berndhose/guacamole-upgrade/blob/master/LICENSE				#
# Report Issues: https://github.com/berndhose/guacamole-upgrade/issues								#
#																									#
# WARNING: For use on RHEL/CentOS 7.x and up only.													#
#	-Use at your own risk!  																		#
#	-Use only for upgrading existing installations of Guacamole version 1.0.0 (and later)!			#
#	-Test prior to deploying on a production system!												#
#####################################################################################################


#####################################################################################################
# User defined directories, adjust to reflect actual Tomcat and Guacamole installation				#
#####################################################################################################
LIB_DIR="/var/lib/guacamole/"							# Directory where guacamole is installed
PROPERTIES_DIR="/etc/guacamole/"						# Directory of guacamole properties
INSTALL_DIR="/usr/local/src/guacamole/${GUAC_VER}/"		# Guacamole source installation dir
WEBAPPS_DIR="/var/lib/tomcat/webapps/"					# Directory of Tomcat webapps
#####################################################################################################
# End of user defined directories																	#
#####################################################################################################

# Check if user is root or sudo
if ! [ $(id -u) = 0 ]; then echo "This script must be run as sudo or root"; exit 1 ; fi

# Get the master version No. of Guacamole from Git
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

# Delete install directory to ensure Git can be cloned
rm -rf ${INSTALL_DIR}

# Create empty install directory
mkdir -vp ${INSTALL_DIR}
cd ${INSTALL_DIR}

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

# Stop Tomcat and guacamole server services
service ${TOMCAT} stop
service guacd stop

# Compile and upgrade Guacamole Server
cd ${INSTALL_DIR}guacamole-server
autoreconf -fi
./configure --with-systemd-dir=/etc/systemd/system
make
make install
ldconfig
systemctl enable guacd

# Cleanup outdated guacamole directory in Tomcat, will be populated again when Tomcat restarts
rm -rf ${WEBAPPS_DIR}guacamole

# Compile and upgrade Guacamole Client
cd ${INSTALL_DIR}guacamole-client
OLD_PATH=${PATH}
export PATH=/opt/maven/bin:${PATH}
mvn package
export PATH=${OLD_PATH}
cp -vf guacamole/target/guacamole-${GUAC_VER}.war ${LIB_DIR}guacamole.war

cd ${INSTALL_DIR}

# Remove old authenticator extensions
rm -rf ${LIB_DIR}extensions/guacamole-auth-jdbc-mysql*
rm -rf ${LIB_DIR}extensions/guacamole-auth-ldap*

# Get JDBC authenticator from compiled client and copy to Tomcat 
find ./guacamole-client/extensions -name "guacamole-auth-jdbc-mysql-${GUAC_VER}.jar" -exec cp -vf {} ${LIB_DIR}extensions/ \;
# Get LDAP authenticator from compiled client and copy to Tomcat 
find ./guacamole-client/extensions -name "guacamole-auth-ldap-${GUAC_VER}.jar" -exec cp -vf {} ${LIB_DIR}extensions/ \;

# Get list of SQL Upgrade Files
cd ./guacamole-client/extensions
UPGRADEFILES=($(ls -1 ./guacamole-auth-jdbc/modules/guacamole-auth-jdbc-mysql/schema/upgrade/ | sort -V))

# Compare SQL Upgrage Files against old guacamole database version, apply upgrades as needed
for FILE in ${UPGRADEFILES[@]}
do
    FILEVERSION=$(echo ${FILE} | grep -oP 'upgrade-pre-\K[0-9\.]+(?=\.)')
    if [[ $(echo -e "${FILEVERSION}\n${OLDVERSION}" | sort -V | head -n1) == ${OLDVERSION} && ${FILEVERSION} != ${OLDVERSION} ]]
    then
        echo "Patching ${DATABASE} with ${FILE}"
        mysql -u ${MYSQL_USER} -h ${MYSQL_SERVER} ${DATABASE} < ./guacamole-auth-jdbc/modules/guacamole-auth-jdbc-mysql/schema/upgrade/${FILE}
    fi
done

# Manage Selinux settings
# Guacamole Client Context
semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}guacamole.war"
restorecon -v "${LIB_DIR}guacamole.war"

# Guacamole JDBC Extension Context
semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}extensions/guacamole-auth-jdbc-mysql-${GUAC_VER}.jar"
restorecon -v "${LIB_DIR}extensions/guacamole-auth-jdbc-mysql-${GUAC_VER}.jar"

# Guacamole LDAP Extension Context
semanage fcontext -a -t tomcat_exec_t "${LIB_DIR}extensions/guacamole-auth-ldap-${GUAC_VER}.jar"
restorecon -v "${LIB_DIR}extensions/guacamole-auth-ldap-${GUAC_VER}.jar"

cd ~

# Start tomcat and guacamole server
service ${TOMCAT} start
service guacd start

exit 0