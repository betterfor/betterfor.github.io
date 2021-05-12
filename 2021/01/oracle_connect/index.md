# 使用Navicate连接Oracle失败 ORA-25847:connection to server failed,probable Orable Net admin error


使用Navicate 15连接Oracle数据库出现如下错误

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/18/oracle_conn_error.png)

通过查询可知是oci.dll版本太低，使用的11.2版本。因为Navicate是通过Oracle客户端连接Oracle服务器，Oracle的客户端分为两种，一种是标准版，一种是简洁版，即Oracle Install Client。出现ORA-28547错误时，多数是因为Navicat本地的OCI版本与Oracle服务器服务器不符造成的。

[OCI下载地址](http://www.oracle.com/technetwork/database/features/instant-client/index-097480.html)

![oracle_download_win](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/18/oracle_download_win.png)

这里看到许多文章提示`不管使用的32位系统还是64位系统都应下载32为的Install Client`

这里我实际操作了一下，64位的系统并不支持32位，所以一定要根据自己的系统版本下载。

打开Navicate程序，打开 “工具” -> "选项" -> "环境" -> "OCI环境"

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/18/naviate_setting.png)

将刚才下载的oci.dll文件完整目录填上，确定后重启Navicate，就会发现可以成功连接了。
