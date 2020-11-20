---
title: "Prometheus"
date: 2020-11-19T18:03:03+08:00
draft: false

tags: ['prometheus','golang']
categories: ['golang']
comment: true
toc: true
autoCollapseToc: false
---

### 简介

prometheus是一个开源的系统监控和警报工具包，最初由SoundCloud开发。自2012年始，许多公司和组织已经采用了prometheus，该项目拥有活跃的开发人员和用户社区。它现在是一个独立的开源项目，独立于任何公司进行维护。着重于此，prometheus在2016年加入CNCF，是继kubernetes之后第二个托管的项目。

官网地址： [Prometheus](https://prometheus.io/)

github地址： [github](https://github.com/prometheus/prometheus)

**架构图**

![](<https://prometheus.io/assets/architecture.png>)

### 下载与安装

#### 二进制

[下载地址](https://prometheus.io/download/)

```
tar xvfz prometheus-*.tar.gz
cd prometheus-*
./prometheus --config.file=prometheus.yml
```

#### docker 

```
docker run --name prometheus -d -p 127.0.0.1:9090:9090 prom/prometheus
```

#### helm

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update

# Helm 3
$ helm install [RELEASE_NAME] prometheus-community/prometheus

# Helm 2
$ helm install --name [RELEASE_NAME] prometheus-community/prometheus

```

#### 配置文件

```yaml
global:
  scrape_interval: 15s # 默认抓取间隔，15s向目标抓取一次数据
  external_labels:
    monitor: 'codelab-monitor'
# 抓取对象
scrape_configs:
  - job_name: 'prometheus' # 名称，会在每一条metrics添加标签{job_name:"prometheus"}
    scrape_interval: 5s # 抓取时间
    static_configs: # 抓取对象
      - targets: ['localhost:9090']
```

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-20/graph.png)

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-20/metrics.png)

部署完毕后，我们可以看到这两个界面。

## 安装exporter

[exporters and integrations](https://prometheus.io/docs/instrumenting/exporters/)

Node Exporter 暴露了如linux等UNIX系统的内核和机器级别的指标(indows用户应用wmi_exporter)。它提供了很多标准的指标如CPU、内存、磁盘空间、硬盘I/O和网络带宽。此外，它还提供了从负负载率平均值到主板温度等很多内核暴露的问题。

下载运行之后，我们需要更新prometheus.yml，然后 **重启** prometheus加载新的配置

```yaml
global:
  scrape_interval: 15s # 默认抓取间隔，15s向目标抓取一次数据
  external_labels:
    monitor: 'codelab-monitor'
# 抓取对象
scrape_configs:
  - job_name: 'prometheus' # 名称，会在每一条metrics添加标签{job_name:"prometheus"}
    scrape_interval: 5s # 抓取时间
    static_configs: # 抓取对象
      - targets: ['localhost:9090']
  - job_name: 'node'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9100']
```

#### 告警

告警分为两个部分。首先需要在prometheus中添加告警规则，定义告警产生的逻辑，其次Altermanager将触发的警报转化为通知，例如邮件，呼叫和聊天消息。

```yaml
global:
  scrape_interval: 15s # 默认抓取间隔，15s向目标抓取一次数据
  evaluation_interval: 10s
  external_labels:
    monitor: 'codelab-monitor'
# 规则文件
rule_files:
  - rules.yml
  
alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - localhost:9093
      
# 抓取对象
scrape_configs:
  - job_name: 'prometheus' # 名称，会在每一条metrics添加标签{job_name:"prometheus"}
    scrape_interval: 5s # 抓取时间
    static_configs: # 抓取对象
      - targets: ['localhost:9090']
  - job_name: 'node'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9100']
```

```yaml
# 规则文件rules.yml
groups:
  - name: example
    rules:
    - alert: InstanceDown
      expr: up == 0
      for: 1m
```

按照 evaluation_interval 的配置，InstanceDown告警每10s将被执行1次。如果持续1m收到数据，那么这个告警就会被触发。在达到设定的时间长度前，这个告警处于 *pending* 状态，在 Alerts 页面可以单击警告查看包括它的标签在内的更多详细信息。

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-20/pending.png)

**注：**通常建议至少5min以减少噪声从而减轻固有监控的各种情况。

既然有一个被触发的告警，需要 Alertmanager 针对它做一些事。

#### Alertmanager

[下载地址](https://prometheus.io/download/)

现在需要为 Alertmanager 创建一个配置文件。这里有很多中方式让Alertmanager 通知到你。这里使用SMTP。

```yaml
global:
  smtp_smarthost: 'localhost:25'
  smtp_from: 'youraddress@example.org'

route:
  receiver: example-email
receivers:
- name: 'example-email'
  email_configs:
  - to: 'youraddress@example.org'

```

启动Alertmanager，现在可以在浏览器输入 *http://localhost:9093* 来访问 Alertmanager，在这个页面你将看到触发的告警，如果所有的配置完成并正常启动，一两分钟后就会收到邮件告警通知。

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-20/alertmanager.png)



## 总结

这个prometheus由exporter、prometheus server、Alertmanager构成。exporter收集数据，prometheus server 拉取exporter数据，然后根据告警规则，将告警推送到Alertmanager处理。中间还衍生了许多其他组件，例如pushgateway(客户端将数据push到pushgateway，由prometheus定期拉取)，grafana等。

