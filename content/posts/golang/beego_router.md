---
title: "Beego路由---前缀树"
date: 2022-03-07T11:09:07+08:00
draft: false

tags: ['beego']
categories: ["月霜天的小随笔"]
comment: true
toc: true
autoCollapseToc: false
---

beego 是一个快速开发 Go 应用的 HTTP 框架，可以用来快速开发 API、Web 及后端服务等各种应用，是一个 RESTful 的框架。

那么这种RESTfule路由到底是怎么实现的？带着这个疑问，我们来了解一下实现过程。

## 一、使用方法

```go
package main

import (
	beego "github.com/beego/beego/v2/server/web"
)

type MainController struct {
	beego.Controller
}

func (this *MainController) Get() {
	this.Ctx.WriteString("Hello world")
}

func main() {
	beego.Router("/", &MainController{})

	beego.Run()
}
```

这个就是beego框架的简单使用。当然还有一些RESTful的使用，这里就不一一赘述了。

## 二、前缀树

Tire树，即字典树，又称单词查找树或键树，是一种树形结构，是一种哈希树的变种。典型应用是用于统计和排序大量的字符串（但不仅限于字符串），所以经常被搜索引擎系统用于文本词频统计。

它的优点是：最大限度地减少无谓的字符串比较，查询效率比哈希表高。

  Trie的核心思想是空间换时间。利用字符串的公共前缀来降低查询时间的开销以达到提高效率的目的。

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/08/tire_tree.png)

那么在字典树中搜索添加过的单词的步骤如下：

1、从根节点开始搜索

2、取得要查找单词的第一个字母，并根据该字母对应的字符路径向下搜索

3、字符路径指向的第二层节点上，根据第二个字母选择对应的字符路径向下继续搜索

4、一直向下搜索，如果单词搜索完成，找到的最后一个节点是叶子节点，说明字典树中存在这个单词，如果找到的不是叶子节点，说明单词不是字典树中添加过的单词。

## 三、beego的前缀树

### 1、数据结构

```go
// 路由树
type ControllerRegister struct {
	routers      map[string]*Tree
}

// 树节点结构
type Tree struct {
	// 路由前缀
	prefix string
	// 完全路由信息
	fixrouters []*Tree
	// if set, failure to match fixrouters search then search wildcard
	wildcard *Tree
	// if set, failure to match wildcard search
	leaves []*leafInfo
}

// 叶子节点结构
type leafInfo struct {
	// names of wildcards that lead to this leaf. eg, ["id" "name"] for the wildcard ":id" and ":name"
	wildcards []string

	// if the leaf is regexp
	regexps *regexp.Regexp

	runObject interface{}
}
```

`ControllerRegister`是所有路由的集合，里面的`routers`是方法的集合，`key`是`http`的方法：`GET`,`POST`,`PUT`等，`Tree`就是路由的前缀树了。

只不过这个路由前缀树和前缀树并不完全相同，还存在通配符`/user/:id`和`/user/*`这种情况，所以添加了`wildcard`用于匹配这两种情况。

### 2、路由注册

我们的路由由以下几种情况：

1、全匹配路由

/user/list

2、正则路由

/user/:id

/user/:id()[0-9]+)

/user/*

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/08/beego_tire_tree.png)

添加路由的时候，实际是调用了

```go
func (p *ControllerRegister) addToRouter(method, pattern string, r *ControllerInfo) {
	if !p.cfg.RouterCaseSensitive {
		pattern = strings.ToLower(pattern)
	}
	if t, ok := p.routers[method]; ok {
		t.AddRouter(pattern, r)
	} else {
		t := NewTree()
		t.AddRouter(pattern, r)
		p.routers[method] = t
	}
}
```

这个代码也简单明了，查找这个路由的**方法树**，如果存在就添加这个方法，如果不存在就新建**方法树**，然后再添加。

而调用的是`AddRouter`这个函数。

```go
// 在路由树上添加路由，pattern是路由信息，runObject是执行方法
func (t *Tree) AddRouter(pattern string, runObject interface{}) {
	t.addseg(splitPath(pattern), runObject, nil, "")
}
```

这个`splitPath`函数就是将路由以`/`分割。

而添加的过程当然是全匹配路由在`fixrouters`，正则路由在`wildcard`。

```go
func (t *Tree) addseg(segments []string, route interface{}, wildcards []string, reg string) {
	if len(segments) == 0 {
        // 在叶子节点上添加方法
		if reg != "" {
			t.leaves = append(t.leaves, &leafInfo{runObject: route, wildcards: wildcards, regexps: regexp.MustCompile("^" + reg + "$")})
		} else {
			t.leaves = append(t.leaves, &leafInfo{runObject: route, wildcards: wildcards})
		}
	} else {
		seg := segments[0]
         // splitSegment起到的作用是分析seg
// "admin" -> false, nil, ""
// ":id" -> true, [:id], ""
// "?:id" -> true, [: :id], ""        : meaning can empty
// ":id:int" -> true, [:id], ([0-9]+)
// ":name:string" -> true, [:name], ([\w]+)
// ":id([0-9]+)" -> true, [:id], ([0-9]+)
// ":id([0-9]+)_:name" -> true, [:id :name], ([0-9]+)_(.+)
// "cms_:id_:page.html" -> true, [:id_ :page], cms_(.+)(.+).html
// "cms_:id(.+)_:page.html" -> true, [:id :page], cms_(.+)_(.+).html
// "*" -> true, [:splat], ""
// "*.*" -> true,[. :path :ext], ""      . meaning separator
		iswild, params, regexpStr := splitSegment(seg)
		// if it's ? meaning can igone this, so add one more rule for it
		if len(params) > 0 && params[0] == ":" {
			t.addseg(segments[1:], route, wildcards, reg)
			params = params[1:]
		}
		// Rule: /login/*/access match /login/2009/11/access
		// if already has *, and when loop the access, should as a regexpStr
		if !iswild && utils.InSlice(":splat", wildcards) {
			iswild = true
			regexpStr = seg
		}
		// Rule: /user/:id/*
		if seg == "*" && len(wildcards) > 0 && reg == "" {
			regexpStr = "(.+)"
		}
		if iswild {
			// ... 省略代码
             // 主要是通配符判断逻辑
			t.wildcard.addseg(segments[1:], route, append(wildcards, params...), reg+regexpStr)
		} else {
			var subTree *Tree
             // 这里添加的是全匹配路由
			for _, sub := range t.fixrouters {
				if sub.prefix == seg {
					subTree = sub
					break
				}
			}
			if subTree == nil {
				subTree = NewTree()
				subTree.prefix = seg
				t.fixrouters = append(t.fixrouters, subTree)
			}
			subTree.addseg(segments[1:], route, wildcards, reg)
		}
	}
}
```

主要就是判断给的路由数据是否存在通配符，然后分情况讨论。

最简单的就是普通路由了，直接添加到`fixrouters`里。

而正则路由根据各种情况，添加到`wildcards`里。

### 3、路由查找

很显然，是要先匹配`fixrouters`，如果没有对应的路由，再到`wildcards`中查找路由，返回对应的`leaves`里的方法。

查找路由的方法和插入的差不多，这里就不贴代码了。

## 四、总结

beego的路由对前缀树做了一点优化，按照`/`分割路由，把这部分放到前缀树的值中，减少了前缀树的深度，毕竟如果按照字符切分的话，前缀树会很深，而且对正则表现也不会友好。
