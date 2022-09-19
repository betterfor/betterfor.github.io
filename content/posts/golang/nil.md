---
title: "Nil的使用场景"
date: 2022-03-07T11:17:34+08:00
draft: false

tags: ['nil']
categories: ["note"]
comment: true
toc: true
autoCollapseToc: false
---

在日常Golang使用中，你有没有这样的疑惑？

`nil`是什么？哪些可以用`nil`？哪些不能用`nil`？

接下来，我将对这些内容进行总结。

## 一、什么是nil

首先`nil`是一个变量，我们可以在源码包中找到这样的描述：

```go
// nil is a predeclared identifier representing the zero value for a
// pointer, channel, func, interface, map, or slice type.
var nil Type // Type must be a pointer, channel, func, interface, map, or slice type

// Type is here for the purposes of documentation only. It is a stand-in
// for any Go type, but represents the same type for any given function
// invocation.
type Type int
```

从类型定义上可以得到以下关键点：

- `nil`本质上是一个`Type`类型的变量
- `Type`类型仅仅是基于`int`定义出来的新类型
- `nil`适用于指针、`channel`、函数、`interface`、`map`、`slice`六种类型

## 二、六大类型

### 1、指针

#### 1.1、变量定义

```go
var ptr *int
```

#### 1.2、变量本身

变量本身是8字节的内存块

#### 1.3、nil赋值

这8个字节指针置0

#### 1.4、nil判断

判断这8个字节是否为0

### 2、channel

#### 2.1、变量定义

```go
// 变量本身定义
var c1 chan struct{}
// 变量定义和初始化
var c2 = make(chan struct{})
```

- 第一种方式仅仅定义了`c1`变量本身
- 第二种方式则分配了`c2`的内存，调用了`runtime`下的`makechan`函数来创建结构

#### 2.2、变量本身

一个 8 字节的指针而已，指向一个 channel 管理结构，也就是 `struct hchan` 的指针。

#### 2.3、nil赋值

赋值 nil 之后，仅仅是把这 8 字节的指针置 0 。

#### 2.4、nil判断

判断这指针是否为0

### 3、map

#### 3.1、变量定义

```go
// 变量定义
var m1 map[int]int
// 变量定义和初始化
var m2 = make(map[int]int)
```

- 第一种方式仅仅定义了`m1`变量本身
- 第二种方式则分配了`m2`的内存，调用了`runtime`下的`makemap`函数来创建结构

#### 3.2、变量本身

变量本身是个指针

```go
// A header for a Go map.
type hmap struct {
	// Note: the format of the hmap is also encoded in cmd/compile/internal/gc/reflect.go.
	// Make sure this stays in sync with the compiler's definition.
	// 键值对的数量
	count int // # live cells == size of map.  Must be first (used by len() builtin)
	// 标识状态
	flags uint8
	// 2^B = len(buckets)
	B uint8 // log_2 of # of buckets (can hold up to loadFactor * 2^B items)
	// 溢出桶里bmap大致数量
	noverflow uint16 // approximate number of overflow buckets; see incrnoverflow for details
	// hash因子
	hash0 uint32 // hash seed
	// 指向一个数组（连续内存空间），数组类型为[]bmap，bmap类型就是存在键值对的结构
	buckets unsafe.Pointer // array of 2^B Buckets. may be nil if count==0.
	// 扩容时，存放之前的buckets
	oldbuckets unsafe.Pointer // previous bucket array of half the size, non-nil only when growing
	// 分流次数，成倍扩容分流操作计数的字段
	nevacuate uintptr // progress counter for evacuation (buckets less than this have been evacuated)
	// 溢出桶结构，正常桶里面某个bmap存满了，会使用这里面的内存空间存放键值对
	extra *mapextra // optional fields
}
```

初始化了`map`结构后，才能分配`map`所使用的内存。

#### 3.3、nil赋值

赋值 nil 之后，仅仅是把这 8 字节的指针置 0 。

#### 3.4、nil判断

判断这指针是否为0

### 4、interface

#### 4.1、变量定义

```go
// 定义一个接口
type Reader interface {
    Read(p []byte) (n int, err error)
}
// 定义一个接口变量
var reader Reader
// 空接口
var empty interface{}
```

#### 4.2、变量本身

```go
type iface struct {
	tab  *itab
	data unsafe.Pointer
}

type eface struct {
	_type *_type
	data  unsafe.Pointer
}
```

其中`iface`是通常定义的interface类型，`eface`是空接口对应的数据结构，这两个结构体占用内存都是16字节。

#### 4.3、nil赋值

赋值 nil 之后，把这 16 字节的内存块置 0 。

#### 4.4、nil判断

需要判断类型和值

### 5、函数

#### 5.1、变量定义

```go
var f func(int) error
```

#### 5.2、变量本身

变量本身是8字节的指针

#### 5.3、nil赋值

本身就是指针，只不过指向的是函数而已，所以赋值也是将这 8 字节置 0 。

#### 5.4、nil判断

判断这8个字节是否为0

### 6、slice

#### 6.1、变量定义

```go
// 定义
var slice1 []int
var slice2 []int = []byte{1,2,3}
// 定义及初始化
var slice3 = make([]int, 3)
```

**`var`和`make`这两种方式有什么区别？**

- 第一种`var`的方式定义变量，如果逃逸分析之后，可以确认分配在栈上，那么就在栈上分配24个字节，如果逃逸到堆上，那么调用`newobject`函数进行类型分析。
- 第二种`make`方式略有不同，如果逃逸分析之后，确认分配在栈上，那么直接在栈上分配24字节，如果逃逸到堆上，会调用`makeslice`来分配变量。

#### 6.2、变量本身

```go
type slice struct {
	array unsafe.Pointer	// 管理的内存块首地址
	len   int				// 动态数组实际使用大小
	cap   int				// 动态数据内存大小
}
```

变量本身占用24字节。

> 我们看到无论是var声明定义的slice变量，还是make创建的slice变量，slice管理结构是已经分配出来的，也就是`struct slice`结构

#### 6.3、nil赋值

本身的 24 字节的内存块被置 0。

#### 6.4、nil判断

那么什么样的`slice`被认为是`nil`？

指针为0，也就是这个动态数组没有实际数据的时候。

问题：仅判断指针？对len和cap两个字段不做判断吗？

```go
package main

import "unsafe"

type sliceType struct {
	pdata unsafe.Pointer
	len int
	cap int
}

func main() {
	var slice []byte
	((*sliceType)(unsafe.Pointer(&slice))).len = 0x3
	((*sliceType)(unsafe.Pointer(&slice))).cap = 0x4

	if slice != nil {
		println("not nil")
	} else {
		println("nil")
	}
}

// Output: nil
```

## 三、总结

1、变量就是绑定到某个内存块上的名称

2、变量定义分配的内存是置零分配的

3、不是所有的类型能够赋值 nil，并且和 nil 进行对比判断。只有 指针、`channel`、函数、`interface`、`map`、`slice` 这 6 种类型

4、`channel`、`map`类型的变量需要`make`才能使用

5、`slice`在声明后可以使用，是因为`struct slice`核心结构在定义的时候就已经分配出来了。

6、`slice`是24字节，`interface`是16字节，其他的都是8字节

7、这 6 种类型和 `nil` 进行比较判断本质上都是和变量本身做判断，slice 是判断管理结构的第一个指针字段，map，channel 本身就是指针
