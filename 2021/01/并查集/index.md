# 并查集


### 并查集
目的: 解决元素分组问题

用途: 
1、判断有向图中是否产生环
2、维护无向图的连通性，判断两个点是否在同一个连通块中

操作:
1、初始化: 每个集合的parent都是自己
2、查询: 查询集合的parent
3、合并: 把不相连的元素合并到同一个集合中

### 方法
1、初始化
假如有编号为1, 2, 3, ..., n的n个元素，我们用一个数组fa[]来存储每个元素的父节点（因为每个元素有且只有一个父节点，所以这是可行的）。
一开始，我们先将它们的父节点设为自己。
```go
var fa = make([]int,n)
for i := 0; i < n; i++ {
    fa[i] = i
}
```

2、查询
我们用递归的写法实现对代表元素的查询：一层一层访问父节点，直至根节点（根节点的标志就是父节点是本身）。
要判断两个元素是否属于同一个集合，只需要看它们的根节点是否相同即可。
```go
find = func(x int) int {
    if x == fa[x] {
        return x
    }
    return find(fa[x])
}
```

**路径压缩方法**
```go
find = func(x int) int {
    if x != fa[x] {
        fa[x] = find(fa[x])
    }
    return fa[x]
}
```

3、合并
合并操作也是很简单的，先找到两个集合的代表元素，然后将前者的父节点设为后者即可。
```go
merge := func(i,j int) {
    fa[find(i)] = find(j)
}
```

**按秩合并**
```go
merge := func(i,j int) {
    xFa,yFa := find(i),find(j)
    if xFa==yFa {
        return
    }
    // x和y不在同一个集合中，合并它们
    if xFa<yFa {
        fa[xFa]=yFa
    } else if xFa > yFa {
        fa[yFa]=xFa
    } else {
        fa[yFa]=xFa
        rank[x]++
    }
}
```

同时使用路径压缩、按秩（rank）合并优化的程序每个操作的平均时间仅为 O(alpha (n))，
其中 alpha (n) 是 { n=f(x)=A(x,x)} 的反函数，A 是急速增加的阿克曼函数。
因为 alpha (n) 是其反函数，故 alpha (n) 在 n 十分巨大时还是小于5。
因此，平均运行时间是一个极小的常数。
实际上，这是渐近最优算法：Fredman 和 Saks 在 1989 年解释了 Omega (alpha (n)) 的平均时间内可以获得任何并查集。

### 例题 Leetcode547
<p>班上有&nbsp;<strong>N&nbsp;</strong>名学生。其中有些人是朋友，有些则不是。他们的友谊具有是传递性。如果已知 A 是 B&nbsp;的朋友，B 是 C&nbsp;的朋友，那么我们可以认为 A 也是 C&nbsp;的朋友。所谓的朋友圈，是指所有朋友的集合。</p>

<p>给定一个&nbsp;<strong>N * N&nbsp;</strong>的矩阵&nbsp;<strong>M</strong>，表示班级中学生之间的朋友关系。如果M[i][j] = 1，表示已知第 i 个和 j 个学生<strong>互为</strong>朋友关系，否则为不知道。你必须输出所有学生中的已知的朋友圈总数。</p>

<p><strong>示例 1:</strong></p>

<pre>
<strong>输入:</strong> 
[[1,1,0],
 [1,1,0],
 [0,0,1]]
<strong>输出:</strong> 2 
<strong>说明：</strong>已知学生0和学生1互为朋友，他们在一个朋友圈。
第2个学生自己在一个朋友圈。所以返回2。
</pre>

<p><strong>示例 2:</strong></p>

<pre>
<strong>输入:</strong> 
[[1,1,0],
 [1,1,1],
 [0,1,1]]
<strong>输出:</strong> 1
<strong>说明：</strong>已知学生0和学生1互为朋友，学生1和学生2互为朋友，所以学生0和学生2也是朋友，所以他们三个在一个朋友圈，返回1。
</pre>

<p><strong>注意：</strong></p>

<ol>
	<li>N 在[1,200]的范围内。</li>
	<li>对于所有学生，有M[i][i] = 1。</li>
	<li>如果有M[i][j] = 1，则有M[j][i] = 1。</li>
</ol>

题解:
```go
func findCircleNum(isConnected [][]int) (ans int) {
	n := len(isConnected)
	parent := make([]int,n)
	for i := range parent {
		parent[i] = i
	}

	var find func(x int) int
	find = func(x int) int {
		if parent[x] != x {
			parent[x] = find(parent[x])
		}
		return parent[x]
	}
	merge := func(from,to int) {
		parent[find(from)] = find(to)
	}
	for i := 0; i < n; i++ {
		for j := i+1; j < n; j++ {
			if isConnected[i][j] == 1 {
				merge(i,j)
			}
		}
	}
	for i, p := range parent {
		if i == p {
			ans++
		}
	}
	return
}
```