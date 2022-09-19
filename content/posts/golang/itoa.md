---
title: "Iota的使用方法"
date: 2021-02-10T20:14:57+08:00
draft: false

tags: ['iota', 'golang']
categories: ["note"]
comment: true
toc: true
autoCollapseToc: false
---

**iota是golang语言的常数计量器，只能在常量的表达式中使用。**

iota在const关键字出现时被重置为0(const内部的第一行之前)。使用iota能简化定义。

1、iota只能在*常量*的表达式使用。

2、每次const出现时，都会让iota初始化为0，使后面的变量自动增长。

```go
const (
	a = iota	// 0
	b			// 1
	c			// 2
)
```

3、允许自定义类型

```go
// go/src/time/time.go
type Weekday int

const (
	Sunday Weekday = iota
	Monday
	Tuesday
	Wednesday
	Thursday
	Friday
	Saturday
)
```

周日对应0，周一对应1，如此类推。

4、可以跳过的值

```go
type Weekday int

const (
	Sunday Weekday = iota
	Monday
	_
	_
	Thursday
	Friday
	Saturday
)
```

对应的值不变，适用场景：某些枚举值可能不需要。

5、位掩码

```go
const (
	a = 1<<iota	 // 1
	b			// 2
	c			// 4
)
```

是连续的2的幂。

6、数量级

```go
const (
    B = 1 << (10*iota)
    KB
    MB
    GB
    TB
)
```

按照这样的生成规则可以按照数量级生成值。

7、定义在一行的情况

```go
const (
	a,b = iota,iota+1	  // 0,1
	c,d					// 1,2
	e,f					// 2,3
)
```

iota会在下一行得到增长，而不是立即获取它的应用。

8、中间插队

```go
const (
	a = iota	// 0
	b = 2		// 2
	c 			// 2
	d = iota	// 3
)
```

```go
const (
	a = 2			// 2
	b = iota		// 1
	c 				// 2
)
```

