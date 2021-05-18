---
title: "如何自定义让json解析出自定义值"
date: 2020-11-25T09:54:07+08:00
draft: false

tags: ['json']
categories: ["月霜天的GO"]
comment: true
toc: false
autoCollapseToc: false
---

## 简介
先来看一下 json.Unmarshal 的注释

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2020-11-25/json_annotation.png)

大意是 json 解析的时候会调用 Unmarshaler 的接口。那么我们就可以自定义解析数据了。

先看一个例子
```go
package main

import (
   "encoding/json"
   "fmt"
   "time"
)

const textJson = `{"name":"xiaoming","duration":"5s"}`

func main() {
   var o Object
   json.Unmarshal([]byte(textJson),&o)
   fmt.Printf("%+v\n",o)
}

type Object struct {
   Name string
   Time time.Duration
}

func (o *Object) UnmarshalJSON(data []byte) error {
   tmp := struct {
      Name   string `json:"name"`
      Duration string    `json:"duration"`
   }{}
   err := json.Unmarshal(data,&tmp)
   if err != nil {
      return err
   }
   dur,err := time.ParseDuration(tmp.Duration)
   if err != nil {
      return err
   }
   o.Name = tmp.Name
   o.Time = dur
   return nil
}
```
你可能觉得打印的数据和textJson没什么区别。
但是实际上打印的o.Time是个时间类型的数据了，从string转到time.Duration类型，这个可以很轻松的转换。

*但是这里还会有一个坑*，来看另一个例子
```go
package main

import (
	"encoding/json"
	"fmt"
	"time"
)

var testJSON = `{"num":5,"duration":"5s"}`

type Nested struct {
	Dur time.Duration `json:"duration"`
}

func (n *Nested) UnmarshalJSON(data []byte) error {
	*n = Nested{}
	tmp := struct {
		Dur string `json:"duration"`
	}{}
	fmt.Printf("parsing nested json %s \n", string(data))
	if err := json.Unmarshal(data, &tmp); err != nil {
		fmt.Printf("failed to parse nested: %v", err)
		return err
	}
	tmpDur, err := time.ParseDuration(tmp.Dur)
	if err != nil {
		fmt.Printf("failed to parse duration: %v", err)
		return err
	}
	(*n).Dur = tmpDur
	return nil
}

type Object struct {
	Nested
	Num int `json:"num"`
}

//uncommenting this method still doesnt help.
//tmp is parsed with the completed json at Nested
//which doesnt take care of Num field, so Num is zero value.
func (o *Object) UnmarshalJSON(data []byte) error {
	*o = Object{}
	tmp := struct {
		Nested
		Num int `json:"num"`
	}{}
	fmt.Printf("parsing object json %s \n", string(data))
	if err := json.Unmarshal(data, &tmp); err != nil {
		fmt.Printf("failed to parse object: %v", err)
		return err
	}
	fmt.Printf("tmp object: %+v \n", tmp)
	(*o).Num = tmp.Num
	(*o).Nested = tmp.Nested
	return nil
}

func main() {
	obj := Object{}
	if err := json.Unmarshal([]byte(testJSON), &obj); err != nil {
		fmt.Printf("failed to parse result: %v", err)
		return
	}
	fmt.Printf("result: %+v \n", obj)
}
```
最终输出的结果是
```text
parsing object json {"num":5,"duration":"5s"} 
parsing nested json {"num":5,"duration":"5s"} 
tmp object: {Nested:{Dur:5s} Num:0} 
result: {Nested:{Dur:5s} Num:0} 
```
这里你可能要疑问了，为什么数据丢失了，num从5变成了0？

那么为什么会出现这种情况呢？

用一个简单的例子说明一下

```go
package main

import "fmt"

type Funer interface{
   Name()string
   PrintName()
}

type A struct {
}

func (a *A) Name() string {
   return "a"
}

func (a *A) PrintName() {
   fmt.Println(a.Name())
}

type B struct {
   A
}

func (b *B) Name() string {
   return "b"
}

func getBer() Funer {
   return &B{}
}

func main() {
   b := getBer()
   b.PrintName()
}
```
这是一个类似继承的实现，它最终会打印 a 。

这是因为golang没有继承方法，它只会调用自己的指针的数据，如果是C/C++，它会实现多态，打印 b 。

这样就会导致 json 数据的接口调用是从外部到内部的接口调用，谁的指针方法就实现谁的指针方法。

那么上面那种情况证明解决呢？
```go
package main

import (
   "encoding/json"
   "fmt"
   "time"
)

var testJSON = `{"num":5,"duration":"5s"}`

type Nested struct {
   Dur time.Duration `json:"duration"`
}

func (obj *Object) UnmarshalJSON(data []byte) error {
   tmp := struct {
      Dur string `json:"duration"`
      Num int    `json:"num"`
   }{}
   if err := json.Unmarshal(data, &tmp); err != nil {
      return err
   }

   dur, err := time.ParseDuration(tmp.Dur)
   if err != nil {
      return err
   }
   obj.Dur = dur
   obj.Num = tmp.Num
   return nil
}

type Object struct {
   Nested
   Num int `json:"num"`
}

var _ json.Unmarshaler = (*Object)(nil)

func main() {
   obj := Object{}
   _ = json.Unmarshal([]byte(testJSON), &obj)
   fmt.Printf("result: %+v \n", obj)
}
```

在内部不使用继承，通过的结构来解析数据就可以了。