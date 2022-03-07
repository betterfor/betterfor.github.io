---
title: "Golang 1.16版本新特性 => 撤回版本(retract)"
date: 2021-02-25T15:15:36+08:00
draft: false

tags: ['golang']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

一般来说，模块作者需要使用一种方法来只是不应该使用某个已发布的模块。

- 出现一个严重的安全漏洞
- 不闲不兼容或bug
- 版本发布错误

> 出现过模块最新版本为1.0.0，错误发布1.1.0，然后在github上把版本删除，使用1.0.1版本，但是有人使用代理模块并且下载了1.1.0版本，所以其他人再下载指定latest会下载1.1.0版本的代码。

## 准备工作

- retract模块，github的完整路径是https://github.com/betterfor/retract，你可以使用自己的模块实验。
- awesomeProjcet，本地模块，使用了test包的依赖的简单main函数。

> 请确保golang版本是1.16+

## 创建test模块

1、先在github上创建好仓库

2、拉取代码仓库

```bash
$ git clone https://github.com/betterfor/retract.git
$ cd retract/
$ go mod init 
go: creating new go.mod: module github.com/betterfor/retract
```

3、在模块中新建`foo.go`文件

```go
package retract

func Foo() string {
	return "v0.0.1"
}
```

4、将`retract`模块的改动提交git并push

```bash
$ git add .
$ git commit -m "Initial commit"
$ git push -u origin master
```

这是模块的初始版本，我们用`v0`版本来表示，代表它不稳定。

```bash
$ git tag v0.1.0
$ git push origin v0.1.0
To https://github.com/betterfor/retract.git
 * [new tag]         v0.1.0 -> v0.1.0
```

此时`retract`模块第一个版本已经发布，我们在`awesomeProjcet`项目使用它。

5、创建`awesomeProjcet`本地项目，引用`retract`模块。

```bash
$ mkdir awesomeProjcet
$ cd awesomeProjcet/
$ go mod init
```

```go
package main

import (
	"fmt"
	"github.com/betterfor/retract"
)

func main() {
	fmt.Println(retract.Foo())
}
```

```bash
$ go get github.com/betterfor/retract@v0.1.0
```

此时版本正常使用。

6、`retract`模块更新
`foo.go`文件修改
```go
package retract

func Foo() string {
	return "v0.2.0"
}
```
我们提交并推送到github上，给它标记一个新的标签`v0.2.0`.
```bash
$ git tag v0.2.0
$ git push origin v0.2.0
```

7、然后我们在`awesomeProjcet`项目中使用`retract`的`v0.2.0`版本，发现可以正常运行。
```bash
$ go get github.com/betterfor/retract@v0.2.0
go: downloading github.com/betterfor/retract v0.2.0
go get: upgraded github.com/betterfor/retract v0.1.0 => v0.2.0
$ go run main.go
v0.2.0
```

8、撤回版本
此时我们作为`retract`模块的作者，发现`v0.2.0`版本不完善，需要撤回这个版本，应该怎么做？

我们可以在`go.mod`中增加`retract`指令来撤回某个模块版本。

```bash
$ go mod edit -retract=v0.2.0
```

此时`go.mod`内容如下
```text
module github.com/betterfor/retract

go 1.16

// tag version error
retract v0.2.0
```

当然你也可以不使用命令，直接在`go.mod`文件中修改，一般会在`retract`加上撤回原因.`go get`、`go list`等会显示这个原因。

提交修改内容至github，给它标记一个新的标签`v0.3.0`。

`awesomeProjcet`项目中使用`retract`的`v0.3.0`版本，发现可以正常运行。

```bash
$ go get github.com/betterfor/retract@v0.3.0
go: downloading github.com/betterfor/retract v0.3.0
go get: upgraded github.com/betterfor/retract v0.2.0 => v0.3.0
$ go get github.com/betterfor/retract@v0.2.0
go: warning: github.com/betterfor/retract@v0.2.0: retracted by module author: tag version error
go: to switch to the latest unretracted version, run:
      go get github.com/betterfor/retract@latestgo get: downgraded github.com/betterfor/retract v0.3.0 => v0.2.0
```

我们发现出现`warning`信息，但是这个版本的包还是可用的。

我们来查看模块的版本列表
```bash
$ go list -m -versions github.com/betterfor/retract
github.com/betterfor/retract v0.1.0 v0.3.0
```
此时我们查看模块的版本发现，没有`v0.2.0`版本了。

通过增加`-retracted`选项可以查看撤回的版本。
```bash
$ go list -m -versions -retracted github.com/betterfor/retract
github.com/betterfor/retract v0.1.0 v0.2.0 v0.3.0
```

那么我们怎么知道我们的项目有没有依赖已撤回版本的模块呢？使用`go list`命令
```bash
$ go list -m -u all
awesomeProjcet
github.com/betterfor/retract v0.2.0 (retracted) [v0.3.0]
```

## 问题
如果模块现在的版本是v0版本，不小心发布了v1版本，需要撤回v1版本，该怎么操作？

1、按照上面的操作步骤进行，我们发现打过`v1.0.0`版本后,仍会显示`v1.0.0`
```bash
$ go list -m -versions github.com/betterfor/retract
github.com/betterfor/retract v0.1.0 v0.3.0 v0.4.0 v1.0.0
```
这就要求我们需要使用一个比`v1.0.0`大的版本号`v1.0.1`来写入撤回信息。
```text
module github.com/betterfor/retract

go 1.16

retract (
    // tag version error
    v0.2.0
    // v1 提前发布了
    [v1.0.0, v1.0.1]
)
```
将这次改动提交，并标记一个新的版本`v1.0.1`。

然后拉取模块
```bash
$ go get github.com/betterfor/retract@v1.0.0
$ go get github.com/betterfor/retract@v1.0.1
$ go get github.com/betterfor/retract@v0.4.0
go list -m -versions github.com/betterfor/retract
github.com/betterfor/retract v0.1.0 v0.3.0 v0.4.0
```
ok! v0.4.0就是最新的版本

> 如果你将来发布v1版本时，应该要从v1.0.2开始，因为v1.0.0和v1.0.1已经被占用了