# 功能描述
- 在全局配置embedding服务的URL
- 对一张指定的表, 指定以下配置
  - 指定信息列, 可以指定多列
  - 指定向量列, 只能指定一列
- 当表数据变更时, 提取信息列合并为一个Json, 通过pg_task在后台线程将json发送给embedding服务计算向量值
- 拿到embedding服务返回向量值后, 保存到指定的向量列
- 提供一个Function, 可以同步地将给定的字符串上传到embedding服务计算并返回向量值, 可用于WHERE语句

  
# 技术需求
- 依赖于`http`扩展和`pg_task`扩展
- 使用[pgTag](https://pgtap.org/documentation.html)做单元测试验证功能.


# 开发环境说明
- Postgres数据库
  - host: localhost
  - port: 5432
  - user: postgres
  - password: 无
- Embedding服务范例
```
curl --request POST \
  --url https://api.siliconflow.cn/v1/embeddings \
  --header 'Authorization: Bearer sk-gjvlkbiknbooainxppvsdheqyxxagzqfgaawnsbjlailjmst' \
  --header 'Content-Type: application/json' \
  --data '{
  "model": "BAAI/bge-m3",
  "input": "Silicon flow embedding online: fast, affordable, and high-quality embedding services. come try it out!"
}'
```
