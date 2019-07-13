# guacamole-upgrade
## Automated script to update Apache Guacamole running on CentOS7 or RHEL7


## MUST READ
This script updates Guacamole installations only, which have been installed from Git with
the installation script from https://github.com/Zer0CoolX/guacamole-install-rhel.
MySQL,LDAP and RADIUS authenticators will be upgraded, if exisiting in extensions directory


**WARNING: Test this script in a development environment prior to using it in a production environment!**

Download the `guac-upgrade.sh` script from this repo:
```
wget https://raw.githubusercontent.com/berndhose/guacamole-upgrade/master/guac-upgrade.sh
```

Make the script executable:
```
chmod +x guac-upgrade.sh
```

Run the script as sudo/root:
```
./guac-upgrade.sh
```

**Credits:**

Shell code used from https://github.com/MysticRyuujin/guac-install and https://github.com/Zer0CoolX/guacamole-install-rhel
