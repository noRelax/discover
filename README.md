# Service Discover for nginx by lua, based sdeploy/nginx

# Install nginx by lua
export LUAJIT_LIB=/usr/local/lib
export LUAJIT_INC=/usr/local/include/luajit-2.0/

./configure --with-http_ssl_module --with-http_v2_module --with-http_gzip_static_module --add-module=/Volumes/Star/Downloads/lua-nginx-module-master --add-module=/usr/local/share/ngx-devel-kit --with-cc-opt='-I/usr/local/Cellar/openssl/1.0.2h_1/include' --with-ld-opt='-L/usr/local/Cellar/openssl/1.0.2h_1/lib'

# Make for test
curl -L 'http://t.cn/RJLkM3A' | sh
sd i nginx
sd i nginx 2
sd i discover
sd i discover 2
echo 'listen	81;' > /opt/nginx2/conf/_nginx.conf.replace
echo 'listen	81;' > /opt/nginx2/apps/app.conf.replace
echo 'shell.export DISCOVER_HOSTS=127.0.0.1:9081	shell.export DISCOVER_HOSTS=127.0.0.1:9080' > /opt/nginx2/apps/discover.conf.replace
echo 'listen	9081;' > /opt/nginx2/apps/discover.conf.replace
