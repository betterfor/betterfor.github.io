# Httprouter


[httprouter](https://github.com/julienschmidt/httprouter)是非常高效的http路由框架，gin框架的路由也是基于此库

## 一、使用方法

使用方法也比较简单，如下：

```go
package main

import (
    "fmt"
    "net/http"
    "log"

    "github.com/julienschmidt/httprouter"
)

func Index(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
    fmt.Fprint(w, "Welcome!\n")
}

func Hello(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
    fmt.Fprintf(w, "hello, %s!\n", ps.ByName("name"))
}

func main() {
    router := httprouter.New()
    router.GET("/", Index)
    router.GET("/hello/:name", Hello)

    log.Fatal(http.ListenAndServe(":8080", router))
}
```

## 二、前缀树

这里在前文已经描述了，[详情看这里](https://www.toutiao.com/i7039200352738198054/)

## 三、具体实现

### 1、Router

```go
type Router struct {
	trees map[string]*node // 存储了http不同方法的根节点

	paramsPool sync.Pool
	maxParams  uint16
	SaveMatchedRoutePath bool
	// 是否通过重定向，给路径自添加/
	RedirectTrailingSlash bool
	// 是否通过重定向，自动修复路径，比如双斜杠等自动修复为单斜杠
	RedirectFixedPath bool
	// 是否检测当前请求的方法被允许
	HandleMethodNotAllowed bool
	// 是否自定答复OPTION请求
	HandleOPTIONS bool
	GlobalOPTIONS http.Handler
	globalAllowed string
	// 404处理
	NotFound http.Handler
	// 不被允许的方法处理
	MethodNotAllowed http.Handler
	// 异常处理
	PanicHandler func(http.ResponseWriter, *http.Request, interface{})
}
```

这里的`trees`同样是存储了方法树，每一个不同的方法都有一个前缀树。

这里的`httproute`性能比`beego`高的一个原因是它使用的`sync.Pool`来优化内存的使用。

### 2、路由注册

在调用`Handle`方法的时候插入路由到路由树中。

```go
func (r *Router) Handle(method, path string, handle Handle) {
	varsCount := uint16(0)

	if method == "" {
		panic("method must not be empty")
	}
	if len(path) < 1 || path[0] != '/' {
		panic("path must begin with '/' in path '" + path + "'")
	}
	if handle == nil {
		panic("handle must not be nil")
	}

	if r.trees == nil {
		r.trees = make(map[string]*node)
	}

	root := r.trees[method]
	if root == nil {
		root = new(node)
		r.trees[method] = root

		r.globalAllowed = r.allowed("*", "")
	}

    // 添加路由到前缀树中
	root.addRoute(path, handle)

	// Lazy-init paramsPool alloc func
	// 初始化pool
	if r.paramsPool.New == nil && r.maxParams > 0 {
		r.paramsPool.New = func() interface{} {
			ps := make(Params, 0, r.maxParams)
			return &ps
		}
	}
}
```

### 3、插入算法

这里插入路由树的方式和beego不同，beego是按照路由`/`来分割的，比如`/user`和`/userinfo`这是对应的两个子树，而`httprouter`将相同前缀合并，`/user`是父节点。

下面给个例子

```text
Priority   Path             Handle
9          \                *<1>
3          ├s               nil
2          |├earch\         *<2>
1          |└upport\        *<3>
2          ├blog\           *<4>
1          |    └:post      nil
1          |         └\     *<5>
2          ├about-us\       *<6>
1          |        └team\  *<7>
1          └contact\        *<8>
```

同样，节点被区分了几种类型

```go
type nodeType uint8

const (
	static nodeType = iota // default 普通节点
	root			// 根节点
	param			// 参数节点
	catchAll		// 通配符
)
```

而节点的数据结构为

```go
type node struct {
	path      string		// 节点对应的路径
	indices   string
	wildChild bool			// 是否是通配符
	nType     nodeType		// 节点类型
	priority  uint32
	children  []*node		// 子节点
	handle    Handle
}
```

### 4、查找路由

`httprouter`是实现了`net/http`的`ServeHTTP`方法

```go
func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if r.PanicHandler != nil {
		defer r.recv(w, req)
	}

	path := req.URL.Path

	if root := r.trees[req.Method]; root != nil {
		if handle, ps, tsr := root.getValue(path, r.getParams); handle != nil {
			if ps != nil {
				handle(w, req, *ps)
				r.putParams(ps)
			} else {
				handle(w, req, nil)
			}
			return
		} 
        // 重定向逻辑
	}
	// 异常处理逻辑
}
```

这里接受到http请求，根据请求的方法和路由信息，查找路由树。

然后根据路由和路由树进行对比，获取到执行的方法。

这一部分比beego的处理稍显简洁。

## 四、总结

`httprouter`使用的路由树比`beego`的路由树更加高效

1、对前缀树再优化，减少了重复的前缀。

2、对路由上的参数获取使用`sync.Pool`方式接受，减少了内存的分配。


