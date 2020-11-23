---
title: "Golang exporter的使用方法"
date: 2020-11-20T15:45:29+08:00
draft: true

tags: ['golang']
categories: ['prometheus']
comment: true
toc: true
autoCollapseToc: false
---

## 前言

在开始监控你的服务之前，你需要通过添加prometheus客户端来添加检测。
可以找 [第三方exporter](https://prometheus.io/docs/instrumenting/exporters/) 监控你的服务，也可以自己编写exporter。

目前已经有很多不同的语言编写的客户端库，包括官方提供的Go，Java，Python，Ruby。
[已有客户端库](<https://prometheus.io/docs/instrumenting/clientlibs/>)

在了解编写exporter之前，可以先[5分钟学会搭建prometheus](<https://betterfor.github.io/2020/11/prometheus/>)

## 简单的exporter服务

先写一个简单的http服务，在9095端口启动了一个能够为prometheus提供监控指标的HTTP服务。你可以在 http://localhost:9095/metrics 看到这些指标。

```go
package main

import (
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("hello world"))
	})
	http.Handle("/metrics",promhttp.Handler())
	http.ListenAndServe(":9095",nil)
}
```

![metrics](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-23/9095metrics.png)

虽然偶尔会手动访问/metrics页面查看指标数据，但是将指标数据导入prometheus才方便。
```yaml
global:
  scrape_interval: 15s # 默认抓取间隔，15s向目标抓取一次数据
  external_labels:
    monitor: 'prometheus-monitor'
# 抓取对象
scrape_configs:
  - job_name: 'exporter' # 名称，会在每一条metrics添加标签{job_name:"prometheus"}
    scrape_interval: 5s # 抓取时间
    static_configs: # 抓取对象
      - targets: ['localhost:9095']
```

那么在 http://localhost:9090/ 浏览器输入 PromQL 表达式 go_info,就会看到如图的结果
![go_info](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-23/goInfo.png)

## 监控指标

### Counter(计数器类型)
Counter记录的是事件的数量或大小，只增不减，除非发生重置。

Counter主要有两个方法
```
# 将counter加1
Inc()
# 增加指定值，如果<0会panic
Add(float64)
```

```go
package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"net/http"
	"time"
)

var (
	failures = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "hq_failture_total",
		Help: "failure counts",
	},[]string{"device"})
)

func init() {
	prometheus.MustRegister(failures)
}

func main() {
	go func() {
		failures.WithLabelValues("/dev/sda").Add(3.2)
		time.Sleep(time.Second)
		failures.WithLabelValues("/dev/sda").Inc()
		time.Sleep(time.Second)
		failures.WithLabelValues("/dev/sdb").Inc()
		time.Sleep(time.Second)
		failures.WithLabelValues("/dev/sdb").Add(1.5)
	}()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("hello world"))
	})
	http.Handle("/metrics",promhttp.Handler())
	http.ListenAndServe(":9095",nil)
}
```

### Gauge(仪表盘类型)
