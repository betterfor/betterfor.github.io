---
title: "Prometheus服务发现"
date: 2020-12-17T13:46:18+08:00
draft: true

tags: ['prometheus']
categories: ["月霜天的小教程"]
comment: true
toc: true
autoCollapseToc: false
---

我们可以通过静态配置static_configs选项能让prometheus发现需要抓取的内容。
这对于简单场景还好，
如果我们将这一套部署在kubernetes上，随着实例的动态增减，必须手动维护prometheus.yml的状态就会很烦人。

// 源码分析