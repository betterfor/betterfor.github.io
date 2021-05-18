---
title: "Defer的使用方法"
date: 2021-02-11T10:31:33+08:00
draft: false

tags: ['defer','golang']
categories: ["月霜天的GO"]
comment: true
toc: true
autoCollapseToc: false
---

## 什么是defer？

`defer`是go语言提供的一种用于注册延迟调用的机制，让函数或语句可以在当前函数执行完毕后（包括通过return正常结束或panic导致的异常结束）执行。

适用场景：

- 打开/关闭连接
- 加锁/释放锁
- 打开/关闭文件等

`defer`在一些需要回收资源的场景非常有用，可以很方便在函数结束前做一些清理工作。

## 为什么要用defer？

在编程过程中，经常需要打开一些资源，比如数据库、文件、锁等，这些资源都需要用完释放，否则会造成内存泄漏。

当然在使用过程中，可以在函数结束时显式关闭资源，但是如果在打开和关闭资源之间如果发生了panic会退出函数，导致关闭资源没有被执行。因为这样一颗语法糖，减少了很多资源泄漏的情况。

## defer底层

官方对`defer`的解释：

> Each time a “defer” statement executes, the function value and parameters to the call are evaluated as usual and saved anew but the actual function is not invoked. Instead, deferred functions are invoked immediately before the surrounding function returns, in the reverse order they were deferred. If a deferred function value evaluates to nil, execution panics when the function is invoked, not when the “defer” statement is executed.

每次`defer`语句执行时，会把函数“压栈”，函数的参数会被拷贝下来，当外层函数退出时，defer函数按照定义的逆序执行，如果defer执行的函数为nil，那么会在最终调用函数产生panic。

这里有一道经典题：

```go
func main() {
	a,b := 1,2
	defer cal("1",a,cal("10",a,b))
	a = 0
	defer cal("2",a,cal("20",a,b))
}

func cal(index string, a, b int) int {
	ret := a + b
	fmt.Println(index,a,b,ret)
	return ret
}

// Output:
10 1 2 3
20 0 2 2
2 0 2 2
1 1 3 4
```

这是遵循先入后出的原则，同时保留当前变量的值。

**看看下面这道题：**

```go
func f1() (r int) {
    defer func() {
        r++
    }
    return 0
}

func f2() (r int) {
    t := 5
    defer func() {
        t = t + 5
    }
    return t
}

func f3() (r int) {
    defer func(r int) {
        r = r + 5
    }(r)
    return 1
}

// Output:
1
5
1
```

---

**你能正确答对吗？**

关键点在于理解这条语句：

```go
return xxx
```

这条语句并不是一个原子命令，经过编译后，变成3条指令：

```
1、返回值=xxx
2、调用defer函数
3、空的return
```

那么我们来拆解上面3个函数。

```go
func f1() (r int) {
    // 1、赋值
    r = 0
    // 2、闭包引用
    defer func() {
        r++
    }
    // 3、空的return
    return 0
}
// defer是闭包引用，所以返回值被修改，所以f1()返回1

func f2() (r int) {
    t := 5
    // 1、赋值
    r = t
    // 2、闭包引用，但没有修改r
    defer func() {
        t = t + 5
    }
    // 3、空的return
    return t
}
// 没涉及返回值r的操作，所以返回5

func f3() (r int) {
    // 1、赋值
    r = 1
    // 2、r作为参数传值，不会修改返回值的r
    defer func(r int) {
        r = r + 5
    }(r)
    // 3、空的return
    return 
}
// 第二步r是作为函数参数使用的，是一份复制，defer语句中的r和外面的r是两个变量，里面r的变化不会改变外面r，所以返回1.
```