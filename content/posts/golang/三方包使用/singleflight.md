---
title: "防缓存击穿---Singleflight"
date: 2021-09-01T16:27:07+08:00
draft: true

tags: ['cache','golang']
categories: ["月霜天的golang"]
comment: true
toc: true
autoCollapseToc: false
---

https://github.com/golang/groupcache/blob/master/singleflight/singleflight.go

## 源码

```go
package singleflight

import "sync"

// call is an in-flight or completed Do call
// call代表需要被执行的函数
type call struct {
	wg  sync.WaitGroup	// 用于阻塞这个调用call的其他请求
	val interface{}		// 函数执行后的结果
	err error			// 函数执行后的error
}

// Group represents a class of work and forms a namespace in which
// units of work can be executed with duplicate suppression.
type Group struct {
	mu sync.Mutex       // protects m
	m  map[string]*call // lazily initialized,对于每一个需要获取的key都有一个对应的call
}

// Do executes and returns the results of the given function, making
// sure that only one execution is in-flight for a given key at a
// time. If a duplicate comes in, the duplicate caller waits for the
// original to complete and receives the same results.
func (g *Group) Do(key string, fn func() (interface{}, error)) (interface{}, error) {
	g.mu.Lock()
	if g.m == nil {
		g.m = make(map[string]*call)
	}
	// 如果获取当前的key的函数正在被执行，则阻塞等待执行中的，等待其执行完毕后获取它的执行结果
	if c, ok := g.m[key]; ok {
		g.mu.Unlock()
		c.wg.Wait()
		return c.val, c.err
	}
	// 初始化一个call，向map中写
	c := new(call)
	c.wg.Add(1)
	g.m[key] = c
	g.mu.Unlock()

	// 执行key对应的函数，将结果赋值call
	c.val, c.err = fn()
	c.wg.Done()

	// 清理现场
	g.mu.Lock()
	delete(g.m, key)
	g.mu.Unlock()

	return c.val, c.err
}
```

